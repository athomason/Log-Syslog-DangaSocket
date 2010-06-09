use strict;
use warnings;

use Test::More tests => 3 + 2 * 3 * 4;
BEGIN { use_ok('Log::Syslog::Async') };
BEGIN { use_ok('Log::Syslog::Async::AnyEvent') };
BEGIN { use_ok('Log::Syslog::Async::DangaSocket') };

use AnyEvent;
use Danga::Socket;
use IO::Select;
use IO::Socket::INET;
use IO::Socket::UNIX;

for my $framework (qw/ AnyEvent Danga::Socket /) {
    for my $proto (qw/ tcp udp unix /) {

        my $test_host = $proto eq 'unix' ? '/tmp/testdevlog' : 'localhost';

        my $listener;
        my $test_port = 0;
        if ($proto eq 'unix') {
            $listener = IO::Socket::UNIX->new(
                Local  => $test_host,
                Listen => 1,
            );
            ok($listener, "$framework/$proto: listen on $test_host");
        }
        else {
            $listener = IO::Socket::INET->new(
                Proto       => $proto,
                LocalHost   => 'localhost',
                LocalPort   => 0,
                ($proto eq 'tcp' ? (Listen => 5) : ()),
                Reuse       => 1,
            );
            $test_port = $listener->sockport;
            ok($listener, "$framework/$proto: listen on port $test_port");
        }

        my $pid = fork;
        die "fork failed" unless defined $pid;

        if (!$pid) {
            sleep 1;
            my $logger = Log::Syslog::Async->new(
                $framework,
                $proto,
                $test_host,
                $test_port,
                'testhost',
                'LogSyslogAsyncTest',
                16,
                5,
            );

            my $send = sub {
                $logger->send('message');
                exit 0;
            };

            if ($framework eq 'Danga::Socket') {
                Danga::Socket->AddTimer(1, $send);
                Danga::Socket->EventLoop;
            }
            elsif ($framework eq 'AnyEvent') {
                my $t = AE::timer(1, 0, $send);
                AE::cv->recv;
            }
            die "shouldn't be here";
        }

        my $receiver;
        if ($proto eq 'tcp' || $proto eq 'unix') {
            $receiver = $listener->accept;
            $receiver->blocking(0);
        }
        else {
            $receiver = $listener;
        }

        my $found = IO::Select->new($receiver)->can_read(3);

        ok($found, "$framework/$proto: didn't time out while waiting for data");

        if ($found) {
            $receiver->recv(my $buf, 256);
            ok($buf =~ /^<133>/, "$framework/$proto: message the right priority");
            ok($buf =~ /message$/, "$framework/$proto: message has the right payload");
        }

        kill 9, $pid;
        waitpid $pid, 0;
        unlink $test_host if $proto eq 'unix';
    }
}
