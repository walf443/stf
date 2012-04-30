package STF::API::Object;
use Mouse;
use Digest::MurmurHash ();
use HTTP::Status ();
use List::Util ();
use STF::Constants qw(
    :object
    :storage
    STF_DEBUG
    STF_ENABLE_OBJECT_META
);
use STF::Dispatcher::PSGI::HTTPException;

with 'STF::API::WithDBI';

has urandom => (
    is => 'rw',
    lazy => 1,
    builder => sub {
        String::Urandom->new( LENGTH => 30, CHARS => [ 'a' .. 'z' ] );
    }
);

has max_num_replica => (
    is => 'rw',
);

has min_num_replica => (
    is => 'rw',
);

sub lookup_meta {
    if ( STF_ENABLE_OBJECT_META ) {
        my ($self, $object_id) = @_;
        return $self->get('API::ObjectMeta')->lookup_for( $object_id );
    }
}

sub status_for {
    my ($self, $id) = @_;

    my $object = $self->find( $id );
    if (! $object ) {
        return (); # no object;
    }

    my @entities = $self->get( 'API::Entity' )->search( {
        object_id => $id
    } );
    $object->{entities} = @entities;
    return $object;
}

# XXX Used only for admin, so efficiency is ignore!
sub search_with_entity_info {
    my ($self, $where, $opts) = @_;
    my $s = $self->sql_maker->new_select;

    my $entity_api = $self->get('API::Entity');
    my @objects = $self->search( $where, $opts );
    foreach my $object (@objects) {
        $object->{entity_count} = $entity_api->count({ object_id => $object->{id } });
    }
    return wantarray ? @objects : \@objects;
}

sub load_objects_since {
    my ($self, $object_id, $limit) = @_;
    my $dbh = $self->dbh('DB::Master');
    my $results = $dbh->selectall_arrayref( <<EOSQL, { Slice => {} }, $object_id, $limit );
        SELECT * FROM object WHERE id > ? LIMIT ?
EOSQL
    return wantarray ? @$results : $results;
}

sub create_internal_name {
    my ($self, $args) = @_;

    my $suffix = $args->{suffix} || 'dat';

    # create 30 characters long random a-z filename
    my $fname = $self->urandom->rand_string;

    if ( $fname !~ /^(.)(.)(.)(.)/ ) {
        die "PANIC: Can't parse file name for directories!";
    }

    File::Spec->catfile( $1, $2, $3, $4, "$fname.$suffix" );
}

sub find_active_object_id {
    my ($self, $args) = @_;
    $self->find_object_id( { %$args, status => OBJECT_ACTIVE } );
}

sub find_object_id {
    my ($self, $args) = @_;
    my ($bucket_id, $object_name) = @$args{ qw(bucket_id object_name) };
    my $dbh = $self->dbh;

    my $sql = <<EOSQL;
        SELECT id FROM object WHERE bucket_id = ? AND name = ?
EOSQL
    my @args = ($bucket_id, $object_name);
    if (exists $args->{status}) {
        push @args, $args->{status};
        $sql .= " AND status = ?";
    }

    my ($id) = $dbh->selectrow_array( $sql, undef, @args );
    return $id;
}

sub find_neighbors {
    my ($self, $object_id, $breadth) = @_;

    if ($breadth <= 0) {
        $breadth = 10;
    }

    my $dbh = $self->dbh;
    # find neighbors (+/- $breadth items)
    my $before = $dbh->selectall_arrayref( <<EOSQL, { Slice => {} }, $object_id );
        SELECT * FROM object WHERE id < ? ORDER BY id DESC LIMIT $breadth 
EOSQL
    my $after = $dbh->selectall_arrayref( <<EOSQL, { Slice => {} }, $object_id );
        SELECT * FROM object WHERE id > ? ORDER BY id ASC LIMIT $breadth 
EOSQL

    return (@$before, @$after)
}

sub find_suspicious_neighbors {
    my ($self, $args) = @_;

    my $object_id = $args->{object_id} or die "XXX no object_id";
    my $storages  = $args->{storages}  or die "XXX no storages";
    my $breadth   = $args->{breadth} || 0;

    if ($breadth <= 0) {
        $breadth = 10;
    }

    my %objects;
    my $dbh = $self->dbh;
    foreach my $storage_id ( @$storages ) {
        # find neighbors in this storage
        my $before = $dbh->selectall_arrayref( <<EOSQL, undef, $storage_id, $object_id );
            SELECT e.object_id FROM entity e FORCE INDEX (PRIMARY)
                WHERE e.storage_id = ? AND e.object_id < ?
                ORDER BY e.object_id DESC LIMIT $breadth
EOSQL
        my $after = $dbh->selectall_arrayref( <<EOSQL, undef, $storage_id, $object_id );
            SELECT e.object_id FROM entity e FORCE INDEX (PRIMARY)
                WHERE e.storage_id = ? AND e.object_id > ?
                ORDER BY e.object_id ASC LIMIT $breadth
EOSQL

        foreach my $row ( @$before, @$after ) {
            my $object_id = $row->[0];
            next if $objects{ $object_id };

            my $object = $self->lookup( $object_id );
            if ($object) {
                $objects{ $object_id } = $object;
            }
        }
    }

    return values %objects;
}

sub create {
    my ($self, $args) = @_;

    my ($object_id, $bucket_id, $object_name, $internal_name, $size, $replicas) =
        delete @$args{ qw(id bucket_id object_name internal_name size replicas) };

    my $dbh = $self->dbh;
    my $rv  = $dbh->do(<<EOSQL, undef, $object_id, $bucket_id, $object_name, $internal_name, $size, $replicas);
        INSERT INTO object (id, bucket_id, name, internal_name, size, num_replica, created_at) VALUES (?, ?, ?, ?, ?, ?, UNIX_TIMESTAMP(NOW()))
EOSQL

    return $rv;
}

# We used to use replicate() for both the initial write and the actual
# replication, but it has been separated out so that you can make sure
# that we make sure we do a double-write in the initial store(), and
# replication that happens afterwards runs with a different logic
sub store {
    my ($self, $args) = @_;

    my $object_id     = $args->{id}            or die "XXX no id";
    my $bucket_id     = $args->{bucket_id}     or die "XXX no bucket_id";
    my $object_name   = $args->{object_name}   or die "XXX no object_name";
    my $internal_name = $args->{internal_name} or die "XXX no internal_name";
    my $input         = $args->{input}         or die "XXX no input";;
    my $size          = $args->{size} || 0;
    my $replicas      = $args->{replicas} || 3; # XXX unused, stored for compat

    my $cluster_api = $self->get('API::StorageCluster');
    $self->create({
        id            => $object_id,
        bucket_id     => $bucket_id,
        object_name   => $object_name,
        internal_name => $internal_name,
        size          => $size,
        replicas      => $replicas, # Unused, stored for back compat
    });

    # Load all possible clusteres, ordered by a consistent hash
    my @clusters = $cluster_api->load_candidates_for( $object_id );
    if (! @clusters) {
        if ( STF_DEBUG ) {
            printf STDERR "[ Replicate] No cluster defined for object %s, and could not any load cluster for it\n",
                    $object_id
                ;
        }
        return;
    }

    # At this point we still don't know which cluster we belong to.
    # Attempt to write into clusters in order.
    foreach my $cluster (@clusters) {
        my $ok = $cluster_api->store({
            cluster   => $cluster,
            object_id => $object_id,
            content   => $input,
            minimum   => 2,
        });
        if ($ok) {
            $cluster_api->register_for_object( {
                cluster_id => $cluster->{id},
                object_id  => $object_id
            });
            # done
            return 1;
        }
    }

    return;
}

sub repair {
    my ($self, $object_id)= @_;

    if (STF_DEBUG) {
        print STDERR "[    Repair] Repairing object $object_id\n";
    }

    my $object = $self->lookup( $object_id );
    my $entity_api = $self->get( 'API::Entity' );
    if (! $object) {
        if (STF_DEBUG) {
            print STDERR "[    Repair] No matching object $object_id\n";
        }

        my @entities = $entity_api->search( {
            object_id => $object_id 
        } );
        if (@entities) {
            if ( STF_DEBUG ) {
                print STDERR "[    Repair] Removing orphaned entities in storages:\n";
                foreach my $entity ( @entities ) {
                    printf STDERR "[    Repair] + %s\n",
                        $entity->{storage_id}
                    ;
                }
            }
            $entity_api->delete( {
                object_id => $object_id
            } );
        }
        return;
    }

    # Attempt to read from any given resource
    my $master_content = $entity_api->fetch_content_from_any({
        object => $object,
    });
    if (! $master_content) {
        if ( STF_DEBUG ) {
            printf STDERR "[    Repair] PANIC: No content for %s could be fetched!! Cannot proceed with repair.\n",
                $object->{id}
            ;
        }
        return;
    }

    my $cluster_api = $self->get( 'API::StorageCluster' );
    my @clusters = $cluster_api->load_candidates_for( $object_id );

    # The object should be inthe first cluster found, so run a health check
    my $ok = $cluster_api->check_entity_health({
        cluster_id => $clusters[0]->{id},
        object_id  => $object_id,
    });

    my $designated_cluster;
    if ($ok) {
        if (STF_DEBUG) {
            printf STDERR "[    Repair] Object %s is correctly stored in cluster %s. Object does not need repair\n",
                $object_id,
                $clusters[0]->{id}
            ;
        }
        $designated_cluster = $clusters[0];
    } else {
        if (STF_DEBUG) {
            printf STDERR "[    Repair] Object %s needs repair\n",
                $object_id
            ;
        }
        # If it got here, either the object was not properly in clusters[0]
        # (i.e., some of the storages in the cluster did not have this object)
        # or it was in a different cluster
        foreach my $cluster ( @clusters ) {
            # The first one is where we should be, but there's always a chance
            # that it's broken, so we need to try all clusters.
            my $ok = $cluster_api->store({
                cluster   => $cluster,
                object_id => $object_id,
                content   => $master_content,
            });
            if ($ok) {
                $designated_cluster = $cluster;
                last;
            }
        }

        if (! $designated_cluster) {
            if (STF_DEBUG) {
                printf STDERR "[    Repair] PANIC: Failed to repair object %s to any cluster!\n",
                    $object_id
                ;
            }
            return;
        }
    }

    # Object is now properly stored in $designated_cluster. Find which storages
    # map to this, and remove any other. This may happen if we added new
    # clusters and rebalancing occurred.
    my $storage_api = $self->get('API::Storage');
    my @storages = $storage_api->search({
        cluster_id => { 'not in' => [ $designated_cluster->{id} ] },
    });
    my @entities = $entity_api->search({
        object_id => $object_id,
        storage_id => { in => [ map { $_->{id} } @storages ] }
    });
    if (@entities) {
        $self->get('API::Entity')->remove({
            object => $object,
            storages => [ map { $storage_api->lookup($_->{storage_id}) } @entities ],
        });
    }
    return 1;
}

sub get_any_valid_entity_url {
    my ($self, $args) = @_;

    my ($bucket_id, $object_name, $if_modified_since, $check) =
        @$args{ qw(bucket_id object_name if_modified_since health_check) };
    my $object_id = $self->find_active_object_id($args);
    if (! $object_id) {
        if (STF_DEBUG) {
            printf STDERR "[Get Entity] Could not get object_id from bucket ID (%s) and object name (%s)\n",
                $bucket_id,
                $object_name
            ;
        }
        return;
    }

    my $object = $self->lookup( $object_id );

    # XXX We have to do this before we check the entities, because in real-life
    # applications many of the requests come with an IMS header -- which 
    # short circuits from this method, and never allows us to reach this
    # enqueuing condition
    if ($check) {
        if ( STF_DEBUG ) {
            printf STDERR "[Get Entity] Object %s forcefully being sent to repair (probably harmless)\n",
                $object_id
            ;
        }
        eval { $self->get('API::Queue')->enqueue( repair_object => $object_id ) };
    }

    # We cache
    #   "storages_for.$object_id => {
    #       $storage_id, $storage_uri ],
    #       $storage_id, $storage_uri ],
    #       $storage_id, $storage_uri ],
    #       ...
    #   ]
    my $repair = 0;
    my $cache_key = [ storages_for => $object_id ];
    my $storages = $self->cache_get( @$cache_key );
    if ($storages) {
        # Got storages, but we need to validate that they are indeed
        # readable, and that the uris match
        my @storage_ids = grep { $_->[0] } @$storages;
        my $storage_api = $self->get('API::Storage');
        my $lookup      = $storage_api->lookup_multi( @storage_ids );

        # If *any* of the storages fail, we should re-compute
        foreach my $storage_id ( @storage_ids ) {
            my $storage = $lookup->{ $storage_id };
            if (! $storage || ! $storage_api->is_readable( $storage ) ) {
                # Invalidate the cached entry, and set the repair flag
                undef $storages;
                $repair++;
                last;
            }
        }
    } 

    if (! $storages) {
        my $dbh = $self->dbh('DB::Master');
        my $sth = $dbh->prepare(<<EOSQL);
            SELECT s.id, s.uri
            FROM object o JOIN entity e ON o.id = e.object_id
                          JOIN storage s ON s.id = e.storage_id 
            WHERE
                o.id = ? AND
                o.status = 1 AND 
                e.status = 1 AND
                s.mode IN ( ?, ? )
EOSQL

        my $rv = $sth->execute($object_id, STORAGE_MODE_READ_ONLY, STORAGE_MODE_READ_WRITE);

        my ($storage_id, $uri);
        $sth->bind_columns(\($storage_id, $uri));

        my %storages;
        while ( $sth->fetchrow_arrayref ) {
            $storages{$storage_id} = $uri;
        }
        $sth->finish;

        my %h = map {
            ( $_ => Digest::MurmurHash::murmur_hash("$storages{$_}/$object->{internal_name}") )
        } keys %storages;
        $storages = [
            map  { [ $_, $storages{$_} ] } 
            sort { $h{$a} <=> $h{$b} }
            keys %h
        ];

        if ( STF_DEBUG ) {
            print STDERR "[Get Entity] Backend storage candidates:\n";
            foreach my $storage ( @$storages ) {
                printf STDERR "[Get Entity] + [%s] %s\n",
                    $storage->[0],
                    $storage->[1]
                ;
            }
        }

        $self->cache_set( $cache_key, $storages, $self->cache_expires );
    }

    # XXX repair shouldn't be triggered by entities < num_replica
    #
    # We used to put the object in repair if entities < num_replica, but
    # in hindsight this was bad mistake. Suppose we mistakenly set
    # num_replica > # of storages (say you have 3 storages, but you
    # specified 5 replicas). In this case regardless of how many times we
    # try to repair the object, we cannot create enough replicas to
    # satisfy this condition.
    #
    # So that check is off. Let ObjectHealth worker handle it once
    # in a while.

    # Send successive HEAD requests
    my $fastest;
    my $furl = $self->get('Furl');
    my $headers;
    if ( $if_modified_since ) {
        $headers = [ 'If-Modified-Since' => $if_modified_since ];
    }

    foreach my $storage ( @$storages ) {
        my $url = "$storage->[1]/$object->{internal_name}";
        my (undef, $code) = $furl->head( $url, $headers );
        if ( HTTP::Status::is_success( $code ) ) {
            if ( STF_DEBUG ) {
                print STDERR "[Get Entity] + HEAD $url OK\n";
            }
            $fastest = $url;
            last;
        } elsif ( HTTP::Status::HTTP_NOT_MODIFIED() == $code ) {
            # XXX if this is was not modified, then short circuit
            if ( STF_DEBUG ) {
                printf STDERR "[Get Entity] IMS request to %s returned NOT MODIFIED. Short-circuiting\n",
                    $object_id
                ;
            }
            STF::Dispatcher::PSGI::HTTPException->throw( 304, [], [] );
        } else {
            if ( STF_DEBUG ) {
                print STDERR "[Get Entity] + HEAD $url failed: $code\n";
            }
            $repair++;
        }
    };

    if ($repair) { # Whoa!
        if ( STF_DEBUG ) {
            printf STDERR "[Get Entity] Object %s needs repair\n",
                $object_id
            ;
        }

        eval { $self->get('API::Queue')->enqueue( repair_object => $object_id ) };

        # Also, kill the cache
        eval { $self->cache_delete( @$cache_key ) };
    }

    if ( STF_DEBUG ) {
        if (! $fastest) {
            print STDERR "[Get Entity] All HEAD requests failed\n";
        } else {
            print STDERR "[Get Entity] HEAD request to $fastest was fastest\n";
        }
    }

    return $fastest || ();
}

# Set this object_id to be deleted. Deletes the object itself, but does
# not delete the entities
sub mark_for_delete {
    my ($self, $object_id) = @_;

    my $dbh = $self->dbh;
    my ($rv_replace, $rv_delete);

    $rv_replace = $dbh->do( <<EOSQL, undef, $object_id );
        REPLACE INTO deleted_object SELECT * FROM object WHERE id = ?
EOSQL

    if ( $rv_replace <= 0 ) {
        if ( STF_DEBUG ) {
            printf STDERR "[  Mark Del] Failed to insert object %s into deleted_object (rv = %s)\n",
                $object_id,
                $rv_replace
        }
    } else {
        if ( STF_DEBUG ) {
            printf STDERR "[  Mark Del] Inserted object %s into deleted_object (rv = %s)\n",
                $object_id,
                $rv_replace
            ;
        }

        $rv_delete = $dbh->do( <<EOSQL, undef, $object_id );
            DELETE FROM object WHERE id = ?
EOSQL

        if ( STF_DEBUG ) {
            printf STDERR "[  Mark Del] Deleted object %s from object (rv = %s)\n",
                $object_id,
                $rv_delete
            ;
        }
    }

    return $rv_replace && $rv_delete;
}

sub rename {
    my ($self, $args) = @_;

    my $source_bucket_id = $args->{ source_bucket_id };
    my $source_object_name = $args->{ source_object_name };
    my $dest_bucket_id = $args->{ destination_bucket_id };
    my $dest_object_name = $args->{ destination_object_name };

    my $source_object_id = $self->find_object_id( {
        bucket_id =>  $source_bucket_id,
        object_name => $source_object_name
    } );

    # This should always exist
    if (! $source_object_id ) {
        if ( STF_DEBUG ) {
            printf STDERR "[    Rename] Source object did not exist (bucket_id = %s, object_name = %s)\n",
                $source_bucket_id,
                $source_object_name
            ;
        }
        return;
    }

    # This shouldn't exist
    my $dest_object_id = $self->find_object_id( {
        bucket_id => $dest_bucket_id,
        object_name => $dest_object_name
    } );
    if ( $dest_object_id ) {
        if ( STF_DEBUG ) {
            printf STDERR "[    Rename] Destination object already exists (bucket_id = %s, object_name = %s)\n",
                $dest_bucket_id,
                $dest_object_name
            ;
        }
        return;
    }

    $self->update( $source_object_id, {
        bucket_id => $dest_bucket_id,
        name      => $dest_object_name
    } );
}

no Mouse;

1;
