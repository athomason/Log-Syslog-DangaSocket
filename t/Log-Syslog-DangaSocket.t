use strict;
use warnings;

use Test::More tests => 1 + 2 * 4;
BEGIN { use_ok('Log::Syslog::DangaSocket') };

use IO::Socket::INET;

my $test_port = 10514;

$SIG{CHLD} = 'IGNORE';

my $proto;
for $proto (qw/ tcp udp /) {

    my $pid = fork;
    die "fork failed" unless defined $pid;

    if (!$pid) {
        sleep 1;
        my $logger = Log::Syslog::DangaSocket->new(
            $proto,
            'localhost',
            $test_port,
            'testhost',
            'LogSyslogDangaSocketTest',
            16,
            5,
        );
        Danga::Socket->AddTimer(1, sub {
            $logger->send('message');
            exit 0;
        } );
        Danga::Socket->EventLoop;
        die "shouldn't be here";
    }

    my $listener = IO::Socket::INET->new(
        Proto       => $proto,
        LocalHost   => 'localhost',
        LocalPort   => $test_port,
        ($proto eq 'tcp' ? (Listen => 5) : ()),
        Reuse       => 1,
    );
    ok($listener, "$proto: listen on port $test_port");

    my $receiver = $listener;
    if ($proto eq 'tcp') {
        $receiver = $listener->accept;
        $receiver->blocking(0);
    }

    vec(my $rin = '', fileno($receiver), 1) = 1;
    #warn "selecting\n";
    my $found = select(my $rout = $rin, undef, undef, 5);
    #warn "done selecting\n";

    ok($found, "$proto: didn't time out while waiting for data");

    if ($found) {
        $receiver->recv(my $buf, 256);
        ok($buf =~ /^<133>/, "$proto: message the right priority");
        ok($buf =~ /message$/, "$proto: message has the right payload");
    }

    kill 9, $pid;
}
