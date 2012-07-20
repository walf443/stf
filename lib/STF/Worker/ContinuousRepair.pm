# ContinuousRepair
#   * only run if there are no other repairs going on
#   * only run if the repair queue isn't big

package STF::Worker::ContinuousRepair;
use Mouse;
use Scope::Guard ();
use STF::Constants qw(:storage STF_DEBUG);
use STF::Utils ();
use STF::Log;

extends 'STF::Worker::Base';
with 'STF::Trait::WithContainer';

has '+interval' => (
    default => 5 * 60 * 1_000_000
);

sub work_once {
    my $self = shift;

    my $o_e0 = $0;
    my $guard = Scope::Guard->new(sub {
        $0 = $o_e0;
    });
    local $STF::Log::PREFIX = "Repair(S)" if STF_DEBUG;
    eval {
        # Signals terminate the process, but don't allow us to fire the
        # guard object, so we manually fire it up
        my $loop = 1;
        my $sig   = sub {
            my $sig = shift;
            return sub {
                $loop = 0;
                undef $guard;
                croakf("Received signal, stopping repair");
            };
        };
        local $SIG{INT}  = $sig->("INT");
        local $SIG{QUIT} = $sig->("QUIT");
        local $SIG{TERM} = $sig->("TERM");

        my $bailout = 0;
        my $limit = 10_000;
        my $object_id = 0;
        my $processed = 0;
        my $queue_api = $self->get('API::Queue');
        my $storage_api = $self->get('API::Storage');
        my $dbh = $self->get('DB::Master');
        my $sth = $dbh->prepare(<<EOSQL);
            SELECT id FROM object WHERE id > ? ORDER BY id ASC LIMIT $limit
EOSQL
        my $size = $queue_api->size( 'repair_object' );
        while ( $loop ) {
            # Halt this process for a while if there are pending
            # repairs. 
            my @storages = $storage_api->search( {
                mode => { IN => [ 
                    STORAGE_MODE_REPAIR_OBJECT,
                    STORAGE_MODE_REPAIR_ENTITY,
                    STORAGE_MODE_REPAIR_OBJECT_NOW,
                    STORAGE_MODE_REPAIR_ENTITY_NOW
                ] }
            } );
            if (@storages > 0)  {
                sleep( 5 * 60 ); # check every 5 minutes
                next;
            }

            if ($sth->execute( $object_id ) <= 0 ) {
                $loop = 0;
                next;
            }

            $sth->bind_columns( \($object_id) );
            while ( $sth->fetchrow_arrayref ) {
                $queue_api->enqueue( repair_object => "NP:$object_id" );
                $processed++;
                $0 = "$o_e0 (object_id: $object_id, $processed)";
            }

            # wait here until we have processed the rows that we just
            # inserted into the repair queue
            my $prev = $size;
            $size = $queue_api->size( 'repair_object' );
            while ( $size > $prev && abs($prev - $size) > $limit * 0.05 ) {
                sleep(60);
                $size = $queue_api->size( 'repair_object' );
            }
        }
    };
    if (my $e = $@) {
        if ($e !~ /Received signal/) {
            Carp::confess("Failed to run repair storage: $e");
        } else {
            Carp::confess("Bailing out because of signal; $e" );
        }
    }
}

no Mouse;

1;