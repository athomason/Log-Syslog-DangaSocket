package Log::Syslog::Async::AnyEvent;

use strict;
use warnings;

use AnyEvent;
use AnyEvent::Handle;
use Carp;
use IO::Socket::INET;
use IO::Socket::UNIX;
use Socket qw(SOL_SOCKET SO_ERROR);

use constant {
    SOCK            => 0,   # IO::Socket object
    CONNECTING      => 1,   # connect timer object before connected, undef afterwards
    WRITE_WATCHER   => 2,   # IO watcher during pre-connect phase
    QUEUE           => 3,   # messages which haven't been fully sent
    HANDLE          => 4,   # AnyEvent::Handle object, once socket is connected
    ERR_HANDLER     => 5,   # subref to call on error
};

our $CONNECT_TIMEOUT = 1;

# $class->new($proto, $host, $port, $err_handler, $messages)
# $err_handler callback will be called with an arrayref of any unsent data
# optional $messages should be arrayref of stringrefs
sub new {
    my $ref   = shift;
    my $class = ref $ref || $ref;

    my $self = bless [], $class;

    # kick off non-blocking connect
    if ($_[0] eq 'unix') {
        $self->[SOCK] = IO::Socket::UNIX->new(
            Peer     => $_[1],
            Blocking => 0,
        );
    }
    else {
        $self->[SOCK] = IO::Socket::INET->new(
            Proto    => $_[0],
            PeerAddr => $_[1],
            PeerPort => $_[2],
            Blocking => 0,
        );
    }

    croak "couldn't create sock: $!" unless defined $self->[SOCK];

    $self->[ERR_HANDLER] = $_[3];

    # start with initial message queue (probably from reconnect) if present
    $self->[QUEUE] = $_[4] || [];

    if ($_[0] eq 'tcp' || $_[0] eq 'unix') {
        # for stream cxns, handle async connection phase here, then delegate to AnyEvent::Handle
        $self->[WRITE_WATCHER] = AE::io($self->[SOCK], 1, sub { $self->event_write(@_) });
        $self->[CONNECTING] = AE::timer($CONNECT_TIMEOUT, 0, sub {
            $self->close;
        });
    }
    else {
        # for dgram cxns, connect is immediate; set up a fake Handle
        $self->[CONNECTING] = undef;
        $self->[HANDLE] = bless {sock => $self->[SOCK], wbuf => ''}, 'DgramHandle';
    }

    return $self;
}

sub event_write {
    my Log::Syslog::Async::AnyEvent $self = shift;
    if ($self->[CONNECTING]) {
        if (!defined $self->[SOCK]) {
            warn "caller is " . pp([caller]) . "\n";
            $self->[WRITE_WATCHER] = undef;
            return;
        }

        my $packed_error = getsockopt($self->[SOCK], SOL_SOCKET, SO_ERROR);
        local $! = unpack('I', $packed_error);

        if ($! == 0) {
            # connected

            $self->[CONNECTING]    =
            $self->[WRITE_WATCHER] = undef;

            $self->[HANDLE] = AnyEvent::Handle->new(
                fh       => $self->[SOCK],
                on_error => sub { $self->close },
                on_eof   => sub { $self->close },
                on_read  => sub { }, # need this to get eof notification
                linger   => 0,
            );

            $self->flush_queue;
        }
        else {
            $self->close;
        }
    }
    else {
        $self->flush_queue;
    }
}

sub write_buffered {
    my Log::Syslog::Async::AnyEvent $self = shift;

    my $message_ref = shift;

    if ($self->[CONNECTING]) {
        # flush will happen upon connection
        push @{ $self->[QUEUE] }, $message_ref;
    }
    else {
        $self->[HANDLE]->push_write($$message_ref);
    }
}

sub flush_queue {
    my Log::Syslog::Async::AnyEvent $self = shift;

    $self->[HANDLE]->push_write($$_) for @{ $self->[QUEUE] };
    $self->[QUEUE] = [];
}

my %Timers;
my $n_timer = 0;

sub close {
    my Log::Syslog::Async::AnyEvent $self = shift;

    return unless $self->[SOCK];

    if ($self->[CONNECTING]) {
        # if we got an error while still trying to connect, back off before trying again
        my $key = $n_timer++;
        $Timers{$key} = AE::timer($CONNECT_TIMEOUT, 0, sub {
            $self->[ERR_HANDLER]->($self->[QUEUE]) if $self->[ERR_HANDLER];
            delete $Timers{$key};
        });
        $self->[CONNECTING] = 1; # disable connect timer since reconnect timer effectively takes over
    }
    elsif ($self->[ERR_HANDLER]) {
        # otherwise try to reconnect immediately
        my $queue = $self->[QUEUE];
        unshift @$queue, \"$self->[HANDLE]{wbuf}" if length $self->[HANDLE]{wbuf};
        $self->[ERR_HANDLER]->($queue);
    }
    $self->[HANDLE]->destroy if $self->[HANDLE];
    $self->[HANDLE] = undef;
    $self->[WRITE_WATCHER] = undef;
    $self->[SOCK]->close;
    $self->[SOCK] = undef;
}

# fake AnyEvent::Handle for udp
sub DgramHandle::push_write {
    my $self = shift;
    $self->{sock}->write(shift);
}
sub DgramHandle::destroy { }

1;
