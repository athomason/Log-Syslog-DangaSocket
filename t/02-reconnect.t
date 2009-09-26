# test that a TCP server which goes away and comes back doesn't cause dropped messages

use strict;
use warnings;

use Test::More tests => 46;

use IO::Socket::INET;
use Log::Syslog::DangaSocket;
use Time::HiRes 'time', 'sleep';

our $DEBUG = 0;
$Log::Syslog::DangaSocket::Socket::DEBUG = $DEBUG;
if ($DEBUG) {
    my $start = time;
    my $parent = $$;
    $SIG{__WARN__} = sub {
        printf STDERR "%f %s: %s",
            time - $start,
            ($$ == $parent ? 'server' : 'client'),
            shift;
    };
}

$SIG{CHLD} = 'IGNORE';

my $test_port = 10514;
my $num_messages = 20;
my $delay = 0.1;

my $parent = $$;

my $pid = fork;
die "fork failed" unless defined $pid;

if (!$pid) {
    $DEBUG && warn "kid is $$\n";
    # child acts as syslog client
    sleep 1; # give parent a chance to start listener

    $DEBUG && warn "creating logger\n";
    my $logger = Log::Syslog::DangaSocket->new(
        'tcp',
        'localhost',
        $test_port,
        'testhost',
        'ReconnectTest',
        16,
        5,
    );

    my $sender;
    $sender = sub {
        my $n = shift;
        $DEBUG && warn "syslogging '$n'\n";
        $logger->send($n);
        Danga::Socket->AddTimer($delay, sub {
            if ($n < $num_messages) {
                $sender->($n+1);
            }
        } );
    };
    $DEBUG && warn "starting to send\n";
    $sender->(0);

    Danga::Socket->AddTimer(10, sub {
        $DEBUG && warn "exiting\n";
        exit 0;
    });
    Danga::Socket->EventLoop;
    die "shouldn't be here";
}
$DEBUG && warn "forked kid $pid\n";

my $listener;
sub start_listener {
    $listener = IO::Socket::INET->new(
        Proto       => 'tcp',
        LocalHost   => 'localhost',
        LocalPort   => $test_port,
        Listen      => 5,
        Reuse       => 1,
    );
}

sub syslogd {
    $SIG{ALRM} = sub { die "No connection received" };
    alarm 3;

    $DEBUG && warn "calling accept\n";
    my $syslogd = $listener->accept;
    $DEBUG && warn "accept returned\n";

    alarm 0;

    pass('got connection');

    $DEBUG && warn "selecting\n";
    vec(my $rin = '', fileno($syslogd), 1) = 1;
    my $found = select(my $rout = $rin, undef, undef, 5);

    ok($found, "didn't time out while waiting for data");

    return $syslogd;
}

$SIG{ALRM} = sub { die "No data read" };
alarm 2*$num_messages*$delay;

start_listener();

my $syslogd = syslogd();
$DEBUG && warn "reading from $syslogd\n";
for my $lineno (0 .. $num_messages/2-1) {
    chomp(my $line = <$syslogd>);
    ok($line, "got line $lineno");
    like($line, qr/: $lineno$/, "right line $lineno");
}
$DEBUG && warn "listener closing\n";
undef $listener;

#sleep $delay;
$DEBUG && warn "server closing\n";
$syslogd->close();

sleep 8*$delay;
$DEBUG && warn "server restarted\n";

start_listener;
$syslogd = syslogd();
$DEBUG && warn "reading from $syslogd\n";
for my $lineno ($num_messages/2 .. $num_messages) {
    chomp(my $line = <$syslogd>);
    ok($line, "got line $lineno");
    like($line, qr/: $lineno$/, "right line $lineno");
}
$DEBUG && warn "done\n";

kill 9, $pid;
