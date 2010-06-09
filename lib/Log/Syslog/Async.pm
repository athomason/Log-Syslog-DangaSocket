=head1 NAME

Log::Syslog::Async - Asynchoronous wrapper around a syslog sending socket
(TCP, UDP, or UNIX).

=head1 SYNOPSIS

    my $logger = Log::Syslog::Async->new(
        $framework,     # 'AnyEvent' or 'Danga::Socket'
        $proto,         # 'udp', 'tcp', or 'unix'
        $dest_host,     # destination hostname or filename
        $dest_port,     # destination port (ignored for unix socket)
        $sender_host,   # sender hostname (informational only)
        $sender_name,   # sender application name (informational only)
        $facility,      # syslog facility number
        $severity,      # syslog severity number
        $reconnect      # whether to reconnect on error
    );

    AnyEvent->timer(after => 5, cb => sub { $logger->send("5 seconds elapsed") });
    AnyEvent->condvar->recv;

    # or

    Danga::Socket->AddTimer(5, sub { $logger->send("5 seconds elapsed") });
    Danga::Socket->EventLoop;

=head1 DESCRIPTION

This module constructs and asynchronously sends syslog packets to a syslogd
listening on a TCP or UDP port, or a UNIX socket. Calls to
C<$logger-E<gt>send()> are guaranteed to never block; though naturally, this
only works in the context of a running asynchronous event loop.

UDP support is present primarily for completeness; an implementation like
L<Log::Syslog::Fast> will provide non-blocking behavior with less overhead.
Only in the unlikely case of the local socket buffer being full will this
module benefit you by buffering the failed write and retrying it when possible,
instead of silently dropping the message. But you should really be using TCP
or a domain socket if you care about reliability.

Trailing newlines are added automatically to log messages.

=head2 ERROR HANDLING

If a fatal occur occurs during sending (e.g. the connection is remotely closed
or reset), Log::Syslog::Async will attempt to automatically reconnect if
$reconnect is true. Any pending writes from the closed connection will be
retried in the new one.

=head1 SEE ALSO

L<AnyEvent>

L<Danga::Socket>

L<Log::Syslog::Constants>

L<Log::Syslog::Fast>

=head1 AUTHOR

Adam Thomason, E<lt>athomason@sixapart.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2009-2010 by Six Apart, E<lt>cpan@sixapart.comE<gt>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.6 or,
at your option, any later version of Perl 5 you may have available.

=cut

package Log::Syslog::Async;

use strict;
use warnings;

use POSIX 'strftime';
use Carp;

our $VERSION = '1.00';

our $CONNECT_TIMEOUT = 1;

# indexes into $self array
use constant {
    # ->new params
    SEND_HOST   => 0,   # where log message originated
    NAME        => 1,   # application-defined logger name
    FACILITY    => 2,   # syslog facility constant
    SEVERITY    => 3,   # syslog severity constant
    RECONNECT   => 4,   # whether to attempt reconnect on error

    # state vars
    SOCK        => 5,   # Log::Syslog::Async::* socket object
    LAST_TIME   => 6,   # last epoch time when a prefix was generated
    PREFIX      => 7,   # stringified time changes only once per second, so cache it and rest of prefix
};

sub new {
    my $ref   = shift;
    my $class = ref $ref || $ref;

    my $mode  = shift;
    my $proto = shift;
    my $host  = shift;
    my $port  = shift;

    my $socket_class;
    if ($mode eq 'Danga::Socket') {
        require Log::Syslog::Async::DangaSocket;
        $socket_class = 'Log::Syslog::Async::DangaSocket';
    }
    elsif ($mode eq 'AnyEvent') {
        require Log::Syslog::Async::AnyEvent;
        $socket_class = 'Log::Syslog::Async::AnyEvent';
    }
    else {
        croak "Async framework $mode not supported";
    }

    my $self = bless [], $class;
    (
        $self->[SEND_HOST], # where log message originated
        $self->[NAME],      # application-defined logger name
        $self->[FACILITY],  # syslog facility constant
        $self->[SEVERITY],  # syslog severity constant
        $self->[RECONNECT], # whether to attempt reconnect on error
    ) = @_;

    my $connecter;
    $connecter = sub {
        my $unsent = shift;
        $self->[SOCK] = $socket_class->new(
            $proto, $host, $port, $connecter, $unsent,
            ($self->[RECONNECT] ? $connecter : ()),
        );
    };
    $connecter->();

    for (SEND_HOST, NAME, FACILITY, SEVERITY) {
        die "missing parameter $_" unless $self->[$_];
    }

    $self->_update_prefix(time);

    return $self;
}

sub facility {
    my $self = shift;
    if (@_) {
        $self->[FACILITY] = shift;
        $self->_update_prefix(time);
    }
    return $self->[FACILITY];
}

sub severity {
    my $self = shift;
    if (@_) {
        $self->[SEVERITY] = shift;
        $self->_update_prefix(time);
    }
    return $self->[SEVERITY];
}

sub _update_prefix {
    my $self = shift;

    # based on http://www.faqs.org/rfcs/rfc3164.html
    my $time_str = strftime('%b %d %H:%M:%S', localtime($self->[LAST_TIME] = shift));

    my $priority = ($self->[FACILITY] << 3) | $self->[SEVERITY]; # RFC3164/4.1.1 PRI Part

    # stringified time changes only once per second, so cache it and rest of prefix
    $self->[PREFIX] = "<$priority>$time_str $self->[SEND_HOST] $self->[NAME]\[$$]: ";
}

sub send {
    my $self = shift;

    # update the log-line prefix only if the time has changed
    my $time = time;
    $self->_update_prefix($time) if $time != $self->[LAST_TIME];

    $self->[SOCK]->write_buffered(\join '', $self->[PREFIX], $_[0], "\n");
}

1;
