# test that a TCP server which goes away and comes back doesn't cause dropped messages

use strict;
use warnings;

use Test::More tests => 2 * 44;

use AnyEvent;
use Danga::Socket;
use IO::Select;
use IO::Socket::INET;
use Log::Syslog::Async;
use Time::HiRes 'time', 'sleep', 'alarm';

use constant DEBUG => 0;
if (DEBUG) {
    my $start = time;
    my $parent = $$;
    $SIG{__WARN__} = sub {
        (my $m = shift) =~ tr/\r\n//d;
        printf STDERR "%f %s: %s\n",
            time - $start,
            ($$ == $parent ? 'server' : 'client'),
            $m;
    };
}

my $early_messages = 5;
my $late_messages = 15;
my $num_messages = $early_messages + $late_messages;
my $delay = 0.4;

my $parent = $$;

sub start_listener {
    my $port = shift;

    my $listener = IO::Socket::INET->new(
        Proto       => 'tcp',
        LocalHost   => 'localhost',
        LocalPort   => $port,
        Listen      => 5,
        Reuse       => 1,
    );
    die "failed to listen: $!" unless $listener;

    return $listener;
}

sub accept_syslogd {
    my $listener = shift;

    DEBUG && warn "selecting on listener\n";
    die "no connection received" unless IO::Select->new($listener)->can_read(3);

    DEBUG && warn "calling accept\n";
    my $syslogd = $listener->accept;
    DEBUG && warn "accept returned\n";

    pass('got connection');

    DEBUG && warn "selecting on syslogd\n";
    my $found = IO::Select->new($syslogd)->can_read(5);

    ok($found, "didn't time out while waiting for data");

    return $syslogd;
}

for my $framework (qw( AnyEvent Danga::Socket )) {

    $SIG{ALRM} = sub { die "No data read" };
    alarm 2*$num_messages*$delay;

    my $listener = start_listener(0);
    my $test_port = $listener->sockport;
    DEBUG && warn "listening on port $test_port\n";

    my $pid = fork;
    die "fork failed" unless defined $pid;

    if (!$pid) {
        # child acts as syslog client
        DEBUG && warn "kid is $$\n";

        undef $listener;

        DEBUG && warn "creating logger to port $test_port\n";
        my $logger = Log::Syslog::Async->new(
            $framework,
            'tcp',
            'localhost',
            $test_port,
            'testhost',
            'ReconnectTest',
            16,
            5,
        );

        my $n = 1;

        # send some messages before event loop
        for (1..$early_messages-1) {
            DEBUG && warn "syslogging $n\n";
            $logger->send($n++);
        }

        my %timers;
        my $n_t = 0;
        my $add_timer =
            $framework eq 'Danga::Socket'
            ? sub {
                Danga::Socket->AddTimer(@_);
            }
            : sub {
                my $key = $n_t++;
                my $cb = $_[1];
                $timers{$key} = AE::timer($_[0], 0, sub { delete $timers{$key}; $cb->() });
            };

        # send rest after
        my $sender;
        $sender = sub {
            my $m = shift;
            DEBUG && warn "syslogging $n\n";
            $logger->send($n++);
            $add_timer->($delay, sub {
                $sender->($m-1) if $m > 0;
            });
        };
        DEBUG && warn "starting delayed send\n";
        $sender->($late_messages);

        DEBUG && warn "starting event loop\n";
        $add_timer->(10, sub {
            DEBUG && warn "exiting\n";
            exit 0;
        });
        if ($framework eq 'Danga::Socket') {
            Danga::Socket->EventLoop;
        }
        else {
            AE::cv->recv;
        }
        die "shouldn't be here";
    }
    DEBUG && warn "forked kid $pid\n";

    my $syslogd = accept_syslogd($listener);
    DEBUG && warn "reading from $syslogd\n";
    for my $lineno (1 .. $num_messages/2) {
        chomp(my $line = <$syslogd>);
        ok($line, "got line $lineno");
        like($line, qr/: $lineno$/, "right line $lineno");
    }

    # close listener first so immedate reconnect fails
    DEBUG && warn "listener closing\n";
    undef $listener;

    DEBUG && warn "server closing\n";
    $syslogd->close();

    DEBUG && warn sprintf "sleeping for %.2fs\n", int($late_messages/2) * $delay;
    select undef, undef, undef, int($late_messages/2) * $delay;
    DEBUG && warn "server restarted\n";

    $listener = start_listener($test_port);
    $syslogd = accept_syslogd($listener);
    DEBUG && warn "reading from $syslogd\n";
    for my $lineno ($num_messages/2+1 .. $num_messages) {
        chomp(my $line = <$syslogd>);
        ok($line, "got line $lineno");
        like($line, qr/: $lineno$/, "right line $lineno");
    }
    DEBUG && warn "done\n";

    kill 9, $pid;
    waitpid $pid, 0;
}
