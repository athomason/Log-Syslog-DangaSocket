package Log::Syslog::DangaSocket::Socket;

use strict;
use warnings;

use Carp;
use POSIX 'strftime';
use Socket qw(SOL_SOCKET SO_ERROR);

use base 'Danga::Socket';

use fields (
    'err_handler',  # subref to call on error
    'connecting',   # connect timer object before connected, undef afterwards
    'unsent_buf',   # messages which haven't been pushed to Danga::Socket
    'sent_buf',     # messages which have been pushed to Danga::Socket but not put on the wire
);

our $CONNECT_TIMEOUT = 1;
our $DEBUG = 0;

# $class->new($proto, $host, $port, $err_handler)
# $err_handler callback will be called with an arrayref of any unsent data
sub new {
    my $ref   = shift;
    my $class = ref $ref || $ref;

    my Log::Syslog::DangaSocket::Socket $self = fields::new($class);

    # kick off non-blocking connect
    my $sock = IO::Socket::INET->new(
        Proto    => $_[0],
        PeerAddr => $_[1],
        PeerPort => $_[2],
        Blocking => 0,
    );

    croak "couldn't create sock: $!" unless $sock;

    $self->SUPER::new($sock);

    $self->{err_handler} = $_[3];

    # get notified when connect completes
    $self->watch_write(1);

    # for prompt error notifications
    $self->watch_read(1);

    $DEBUG && warn "$self created\n";

    $self->{connecting} = Danga::Socket->AddTimer(
        $CONNECT_TIMEOUT, sub { $self->close }
    );

    return $self;
}

# normally syslogs doesn't send anything back. if an error occurs (like remote
# side closing the connection), we'll be notified of eof this way
sub event_read {
    my Log::Syslog::DangaSocket::Socket $self = shift;
    my $read = sysread $self->{sock}, my $buf, 1;
    $self->close if defined $read && $read == 0; # eof
}

sub write_buffered {
    my Log::Syslog::DangaSocket::Socket $self = shift;

    my $message_ref = shift;
    if ($self->{connecting}) {
    $DEBUG && warn "buffered $$message_ref\n";
        push @{ $self->{unsent_buf} }, $message_ref;
    }
    else {
        $self->write_through($message_ref);
    }
}

sub write_through {
    my Log::Syslog::DangaSocket::Socket $self = shift;
    my $message_ref = shift;
    push @{ $self->{sent_buf} }, $message_ref;
    my $m;
    chomp($m = $$message_ref) if $DEBUG;
    $DEBUG && warn "pushed $m\n";
    $self->write($message_ref);
    $self->write(sub {
        shift @{ $self->{sent_buf} };
        $DEBUG && warn "write finished of '$m'\n";
    });
}

sub event_write {
    my Log::Syslog::DangaSocket::Socket $self = shift;
    $DEBUG && warn "entering event_write\n";
    if ($self->{connecting}) {
        my $packed_error = getsockopt($self->sock, SOL_SOCKET, SO_ERROR);
        local $! = unpack('I', $packed_error);

        if ($! == 0) {
            if (my $queued = $self->{unsent_buf}) {
                while (my $message_ref = shift @$queued) {
                    $self->write_through($message_ref);
                }
                @$queued = ();
            }

            $DEBUG && warn "connected\n";
            $self->{connecting}->cancel;
            $self->{connecting} = undef;
            $self->watch_write(0);
        }
        else {
            $DEBUG && warn "connect error: $!\n";
            $self->close;
        }
    }
    $self->SUPER::event_write(@_);
}

sub unsent {
    my Log::Syslog::DangaSocket::Socket $self = shift;
    return $self->{connecting} ? $self->{unsent_buf} : $self->{sent_buf};
}

sub close {
    my Log::Syslog::DangaSocket::Socket $self = shift;
    return if $self->{closed};
    $DEBUG && warn "closing\n";
    if ($self->{connecting}) {
        # if we got an error while still trying to connect, back off before trying again
        $DEBUG && warn "error while connecting\n";
        Danga::Socket->AddTimer($CONNECT_TIMEOUT, sub {
            $DEBUG && warn "retrying connect\n";
            $self->{err_handler}->($self->unsent());
        });
    }
    else {
        # otherwise try to reconnect immediately
        $self->{err_handler}->($self->unsent);
    }
    $self->SUPER::close(@_);
}

*event_err = \&close;
*event_hup = \&close;

1;
