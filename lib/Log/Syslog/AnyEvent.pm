package Log::Syslog::AnyEvent;

use strict;
use warnings;

use Log::Syslog::Async;

our @ISA = qw(Log::Syslog::Async);

sub new {
    my $class = shift;
    return $class->SUPER::new('AnyEvent', @_);
}

1;
