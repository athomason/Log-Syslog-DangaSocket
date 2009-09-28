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
    'queue',        # messages which haven't been fully sent
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

    $self->{queue} = [];

    $DEBUG && warn "$self created\n";

    $self->{connecting} = Danga::Socket->AddTimer(
        $CONNECT_TIMEOUT, sub { $self->close }
    );

    return $self;
}

sub write_buffered {
    my Log::Syslog::DangaSocket::Socket $self = shift;

    my $message_ref = shift;
    push @{ $self->{queue} }, $message_ref;

    if ($DEBUG) {
        my $m;
        chomp($m = $$message_ref) if $DEBUG;
        $DEBUG && warn "queued $m\n";
    }

    # flush will happen upon connection
    $self->flush_queue unless $self->{connecting};
}

sub flush_queue {
    my Log::Syslog::DangaSocket::Socket $self = shift;
    my $queue = $self->{queue};

    for my $message_ref (@$queue) {
        # give the message to Danga::Socket...
        $self->write($message_ref);

        # but only forget it in the local queue once notified that the write completed
        $self->write(sub {
            shift @$queue;
            $DEBUG && warn "write finished of '$$message_ref'\n";
            if ($DEBUG) {
                my $m;
                chomp($m = $$message_ref) if $DEBUG;
                $DEBUG && warn "completed '$m'\n";
            }
        });
    }
}

# 
sub event_write {
    my Log::Syslog::DangaSocket::Socket $self = shift;
    $DEBUG && warn "entering event_write\n";
    if ($self->{connecting}) {
        my $packed_error = getsockopt($self->sock, SOL_SOCKET, SO_ERROR);
        local $! = unpack('I', $packed_error);

        if ($! == 0) {
            # connected
            $DEBUG && warn "connected\n";
            $self->{connecting}->cancel;
            $self->{connecting} = undef;
            $self->watch_write(0);
            $self->flush_queue;
        }
        else {
            $DEBUG && warn "connect error: $!\n";
            $self->close;
        }
    }
    $self->SUPER::event_write(@_);
}

# normally syslogd doesn't send anything back. if an error occurs (like remote
# side closing the connection), we'll be notified of eof this way
sub event_read {
    my Log::Syslog::DangaSocket::Socket $self = shift;
    my $read = sysread $self->{sock}, my $buf, 1;
    $self->close if defined $read && $read == 0; # eof
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
            $self->{err_handler}->($self->{queue});
        });
    }
    else {
        # otherwise try to reconnect immediately
        $self->{err_handler}->($self->{queue});
    }
    $self->SUPER::close(@_);
}

*event_err = \&close;
*event_hup = \&close;

1;
