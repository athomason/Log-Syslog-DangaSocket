# test that a TCP server which goes away and comes back doesn't cause dropped messages

use strict;
use warnings;

use Test::More tests => 46;

use IO::Select;
use IO::Socket::INET;
use Log::Syslog::DangaSocket;
use Time::HiRes 'time', 'sleep';

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
my $delay = 0.1;

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
    my $logger = Log::Syslog::DangaSocket->new(
        'tcp',
        'localhost',
        $test_port,
        'testhost',
        'ReconnectTest',
        16,
        5,
    );

    my $n = 0;

    # send some messages before event loop
    for (0..$early_messages-1) {
        DEBUG && warn "syslogging $n\n";
        $logger->send($n++);
    }

    # send rest after
    my $sender;
    $sender = sub {
        my $m = shift;
        DEBUG && warn "syslogging $n\n";
        $logger->send($n++);
        Danga::Socket->AddTimer($delay, sub {
            $sender->($m-1) if $m > 0;
        } );
    };
    DEBUG && warn "starting delayed send\n";
    $sender->($late_messages);

    DEBUG && warn "starting event loop\n";
    Danga::Socket->AddTimer(10, sub {
        DEBUG && warn "exiting\n";
        exit 0;
    });
    Danga::Socket->EventLoop;
    die "shouldn't be here";
}
DEBUG && warn "forked kid $pid\n";

sub accept_syslogd {
    my $listener = shift;

    die "no connection received" unless IO::Select->new($listener)->can_read(3);

    DEBUG && warn "calling accept\n";
    my $syslogd = $listener->accept;
    DEBUG && warn "accept returned\n";

    pass('got connection');

    DEBUG && warn "selecting\n";
    my $sel = IO::Select->new($syslogd);
    my $found = $sel->can_read(5);

    ok($found, "didn't time out while waiting for data");

    return $syslogd;
}

my $syslogd = accept_syslogd($listener);
DEBUG && warn "reading from $syslogd\n";
for my $lineno (0 .. $num_messages/2-1) {
    chomp(my $line = <$syslogd>);
    ok($line, "got line $lineno");
    like($line, qr/: $lineno$/, "right line $lineno");
}

# close listener first so immedate reconnect fails
DEBUG && warn "listener closing\n";
undef $listener;

DEBUG && warn "server closing\n";
$syslogd->close();

sleep int($late_messages/2) * $delay;
DEBUG && warn "server restarted\n";

$listener = start_listener($test_port);
$syslogd = accept_syslogd($listener);
DEBUG && warn "reading from $syslogd\n";
for my $lineno ($num_messages/2 .. $num_messages) {
    chomp(my $line = <$syslogd>);
    ok($line, "got line $lineno");
    like($line, qr/: $lineno$/, "right line $lineno");
}
DEBUG && warn "done\n";

kill 9, $pid;
waitpid $pid, 0;
