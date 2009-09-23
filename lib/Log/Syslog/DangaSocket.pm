=head1 NAME

Log::Syslog::DangaSocket - Danga::Socket wrapper around a syslog sending socket
(TCP or UDP).

=head1 SYNOPSIS

    my $logger = Log::Syslog::DangaSocket->new(
        $proto,         # 'udp' or 'tcp'
        $dest_host,     # destination hostname
        $dest_port,     # destination port
        $sender_host,   # sender hostname (informational only)
        $sender_name,   # sender application name (informational only)
        $facility,      # syslog facility number
        $severity,      # syslog severity number
        $err_handler    # error callback
    );

    Danga::Socket->AddTimer(5, sub { $logger->send("5 seconds elapsed") });

    Danga::Socket->EventLoop;

=head1 DESCRIPTION

This module constructs and asynchronously sends syslog packets to a syslogd
listening on a TCP or UDP port. Calls to C<$logger-E<gt>send()> are guaranteed to
never block; though naturally, this only works in the context of a running
Danga::Socket event loop.

UDP support is present primarily for completeness; an implementation like
L<Log::Syslog::Fast> will provide non-blocking behavior with less overhead.
Only in the unlikely case of the local socket buffer being full will this
module benefit you by buffering the failed write and retrying it when possible,
instead of silently dropping the message. But you should really be using TCP if
you care about reliability.

Trailing newlines are added automatically to log messages.

=head1 SEE ALSO

L<Danga::Socket>

L<Log::Syslog::Fast>

=head1 AUTHOR

Adam Thomason, E<lt>athomason@sixapart.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2009 by Six Apart, E<lt>cpan@sixapart.comE<gt>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.6 or,
at your option, any later version of Perl 5 you may have available.

=cut

package Log::Syslog::DangaSocket;

our $VERSION = '1.00';

use POSIX 'strftime';

use base 'Danga::Socket';

use fields (
    'send_host',    # where log message originated
    'name',         # application-defined logger name
    'facility',     # syslog facility constant
    'severity',     # syslog severity constant
    'err_handler',  # subref to call on error
    'last_time',    # last epoch time when a prefix was generated
    'prefix',       # stringified time changes only once per second, so cache it and rest of prefix
);

sub new {
    my $class = shift;
    my $proto = shift;
    my $host  = shift;
    my $port  = shift;

    my $sock = IO::Socket::INET->new(
        Proto    => $proto,
        PeerAddr => $host,
        PeerPort => $port,
        Blocking => 0,
    );

    my Log::Syslog::DangaSocket $self = fields::new($class);
    $self->SUPER::new($sock);

    ( $self->{send_host},
      $self->{name},
      $self->{facility},
      $self->{severity},
      $self->{err_handler} ) = @_;

    for (qw/ send_host name facility severity /) {
        die "missing parameter $_" unless $self->{$_};
    }

    $self->_update_prefix(time);

    return $self;
}

sub _update_prefix {
    my $self = shift;

    # based on http://www.faqs.org/rfcs/rfc3164.html
    my $time_str = strftime('%b %d %H:%M:%S', localtime($self->{last_time} = shift));

    my $priority = ($self->{facility} << 3) | $self->{severity}; # RFC3164/4.1.1 PRI Part

    $self->{prefix} = "<$priority>$time_str $self->{send_host} $self->{name}\[$$]: ";
}

sub send {
    my Log::Syslog::DangaSocket $self = shift;

    # update the log-line prefix only if the time has changed
    my $time = time;
    $self->_update_prefix($time) if $time != $self->{last_time};

    $self->write(\join '', $self->{prefix}, $_[0], "\n");
}

# syslogd shouldn't be talking back
sub event_read { }

sub on_error {
    my $self = shift;
    $self->close;
    $self->{err_handler}->($self) if $self->{err_handler};
}
*event_err = \&on_error;
*event_hup = \&on_error;

1;
