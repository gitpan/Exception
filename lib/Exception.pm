#!/usr/bin/perl -c

package Exception;
our $VERSION = 0.01;

=head1 NAME

Exception - Lightweight exceptions

=head1 SYNOPSIS

  # Use module and create needed exceptions
  use Exception (
    'Exception::IO',
    'Exception::FileNotFound' => { isa => 'Exception::IO' },
  );

  # try / catch
  try Exception eval {
    do_something() or throw Exception::FileNotFound
                                message=>'Something wrong',
                                tag=>'something';
  };
  if (catch Exception my $e) {
    # $e is an exception object for sure, no need to check if is blessed
    if ($e->isa('Exception::IO')) { warn "IO problem"; }
    elsif ($e->isa('Exception::Die')) { warn "eval died"; }
    elsif ($e->isa('Exception::Warn')) { warn "some warn was caught"; }
    elsif ($e->with(tag=>'something')) { warn "something happened"; }
    elsif ($e->with(qr/^Error/)) { warn "some error based on regex"; }
    else { $e->throw; } # rethrow the exception
  }

  # the exception can be thrown later
  $e = new Exception;
  $e->throw;

  # try with array context
  @v = try Exception [eval { do_something_returning_array(); }];

  # use syntactic sugar
  use Exception qw[try catch];
  try eval {
    throw Exception;
  };    # don't forget about semicolon
  catch my $e, ['Exception::IO'];

=head1 DESCRIPTION

This class implements a fully OO exception mechanism similar to
Exception::Class or Class::Throwable.  It does not depend on other modules
like Exception::Class and it is more powerful than Class::Throwable.  Also it
does not use closures as Error and does not polute namespace as
Exception::Class::TryCatch.  It is also much faster than Exception::Class.

The features of Exception:

=over 2

=item *

fast implementation of an exception object

=item *

fully OO without closures and source code filtering

=item *

does not mess with $SIG{__DIE__} and $SIG{__WARN__}

=item *

no external modules dependencies, requires core Perl modules only

=item *

implements error stack, the try/catch blocks can be nested

=item *

shows full backtrace stack on die by default

=item *

the default behaviour of exception class can be changed globally or just for
the thrown exception

=item *

the exception can be created with defined custom properties

=item *

matching the exception by class, message or custom properties

=item *

matching with string, regex or closure function

=item *

creating automatically the derived exception classes ("use" interface)

=item *

easly expendable, see Exception::System class for example

=back

=cut


use strict;

use Carp ();
use Exporter ();


# Export try/catch syntactic sugar
our @EXPORT_OK = qw(try catch);


# Overload the stringify operation
use overload q|""| => "_stringify", fallback => 1;


# List of class fields (name => {is=>ro|rw, default=>value})
use constant FIELDS => {
    message      => { is => 'rw', default => 'Unknown exception' },
    caller_stack => { is => 'ro' },
    egid         => { is => 'ro' },
    euid         => { is => 'ro' },
    gid          => { is => 'ro' },
    pid          => { is => 'ro' },
    tid          => { is => 'ro' },
    properties   => { is => 'ro' },
    time         => { is => 'ro' },
    uid          => { is => 'ro' },
    verbosity    => { is => 'rw', default => 3 },
    max_arg_len  => { is => 'rw', default => 64 },
    max_arg_nums => { is => 'rw', default => 8 },
    max_eval_len => { is => 'rw', default => 0 },
};


# Cache for class' FIELDS
my %Class_Fields;


# Cache for class' defaults
my %Class_Defaults;


# Exception stack for try/catch blocks
my @Exception_Stack;


# Export try/catch and create additional exception packages
sub import {
    my $pkg = shift;

    my @export;

    while (defined $_[0]) {
        my $name = shift;
        if ($name eq 'try' or $name eq 'catch') {
            push @export, $name;
        }
        else {
            if ($pkg ne __PACKAGE__) {
                Carp::croak("Exceptions can only be created with " . __PACKAGE__ . " class");
            }
            if ($name eq __PACKAGE__) {
                Carp::croak(__PACKAGE__ . " class can not be created automatically");
            }
            my $isa = __PACKAGE__;
            my $version = 0.1;
            if (defined $_[0] and ref $_[0] eq 'HASH') {
                my $param = shift;
                $isa = $param->{isa} if defined $param->{isa};
                $version = $param->{version} if defined $param->{version};
            }
            my $code = << "END";
package ${name};
use base qw(${isa});
our \$VERSION = ${version};
END
            eval $code;
            if ($@) {
                Carp::croak("An error occured while constructing " . __PACKAGE__ . " exception class ($name) : $@");
            }
        }
    }

    if (@export) {
        my $callpkg = caller;
        Exporter::export($pkg, $callpkg, @export);
    }

    return 1;
}


# Unexport try/catch
sub unimport {
    my $pkg = shift;
    my $callpkg = caller;

    my @export = scalar @_ ? @_ : qw[catch try];

    no strict 'refs';
    while (my $name = shift @export) {
        if ($name eq 'try' or $name eq 'catch') {
            if (defined &{$callpkg . '::' . $name}) {
                delete ${$callpkg . '::'}{$name};
            }
        }
    }

    return 1;
}


# Constructor
sub new {
    my $class = shift;
    $class = ref $class if ref $class;

    my $fields;
    my $defaults;

    # Use cached value if available
    if (not defined $Class_Fields{$class}) {
        $fields = $Class_Fields{$class} = $class->FIELDS;
        $defaults = $Class_Defaults{$class} = {
            map { $_ => $fields->{$_}->{default} }
                grep { defined $fields->{$_}->{default} }
                    (keys %$fields)
        };
    }
    else {
        $fields = $Class_Fields{$class};
        $defaults = $Class_Defaults{$class};
    }

    my $self = {};

    # If the attribute is rw, initialize its value. Otherwise: properties.
    my %args = @_;
    $self->{properties} = {};
    foreach my $key (keys %args) {
        if (defined $fields->{$key} and $fields->{$key}->{is} eq 'rw') {
            $self->{$key} = $args{$key};
        }
        else {
            $self->{properties}->{$key} = $args{$key};
        }
    }

    # Defaults for this object
    $self->{defaults} = { %$defaults };

    return bless $self => $class;
}


# Create the exception and throw it or rethrow existing
sub throw {
    my $self = shift;

    # rethrow the exception; update the system data
    if (__blessed($self) and $self->isa(__PACKAGE__)) {
        $self->_collect_system_data;
        die $self;
    }

    # new exception
    my $e = $self->new(@_);

    $e->_collect_system_data;
    die $e;
}


# Convert an exception to string
sub stringify {
    my $self = shift;
    my $verbosity = shift;
    my $message = shift;

    $verbosity = defined $self->{verbosity} ? $self->{verbosity} : $self->{defaults}->{verbosity}
        if not defined $verbosity;
    $message = defined $self->{message} ? $self->{message} : $self->{defaults}->{message}
        if not defined $message;

    my $string;

    if ($verbosity == 1) {
        $string = $message . "\n";
    }
    elsif ($verbosity == 2) {
        $string = sprintf "%s at %s line %d.\n",
            $message,
            defined $self->{caller_stack} && $self->{caller_stack}->[0]->[1]
                ? $self->{caller_stack}->[0]->[1]
                : 'unknown',
            defined $self->{caller_stack} && $self->{caller_stack}->[0]->[2]
                ? $self->{caller_stack}->[0]->[2]
                : 0;
    }
    elsif ($verbosity >= 3) {
        $string .= sprintf "%s: %s", ref $self, $message;
        $string .= $self->_caller_backtrace;
    }
    else {
        $string = "";
    }

    return $string;
}


# Stringify for overloaded operator
sub _stringify {
    my $self = shift;
    return $self->stringify();
}


# Check if an exception object has some attributes
sub with {
    my $self = shift;
    return unless @_;

    # Odd number of arguments - first is message
    if (scalar @_ % 2 == 1) {
        my $message = shift;
        if (not defined $message) {
            return 0 if defined $self->{message};
        }
        elsif (not defined $self->{message}) {
            return 0;
        }
        elsif (ref $message eq 'CODE') {
            $_ = $self->{message};
            return 0 if not &$message;
        }
        elsif (ref $message eq 'Regexp') {
            $_ = $self->{message};
            return 0 if not /$message/;
        }
        else {
            return 0 if $self->{message} ne $message;
        }
    }

    my %args = @_;
    while (my($key,$val) = each %args) {
        return 0 if not defined $val and
            defined $self->{properties}->{$key} || exists $self->{$key} && defined $self->{$key};

        return 0 if defined $val and not
            defined $self->{properties}->{$key} || exists $self->{$key} && defined $self->{$key};

        if (defined $val and
            defined $self->{properties}->{$key} || exists $self->{$key} && defined $self->{$key})
        {
            if (ref $val eq 'CODE') {
                if (defined $self->{properties}->{$key}) {
                    $_ = $self->{properties}->{$key};
                    next if &$val;
                }
                return 0 unless exists $self->{$key} and defined $self->{$key};
                $_ = $self->{$key};
                return 0 if not &$val;
            }
            elsif (ref $val eq 'Regexp') {
                if (defined $self->{properties}->{$key}) {
                    $_ = $self->{properties}->{$key};
                    next if /$val/;
                }
                return 0 unless exists $self->{$key} and defined $self->{$key};
                $_ = $self->{$key};
                return 0 if not /$val/;
            }
            else {
                next if defined $self->{properties}->{$key} and $self->{properties}->{$key} eq $val;
                return 0 unless exists $self->{$key} and defined $self->{$key};
                return 0 if $self->{$key} ne $val;
            }
        }
    }

    return 1;
}


# Push the exception on error stack. Stolen from Exception::Class::TryCatch
sub try ($) {
    # Can be used also as function
    my $self = shift if defined $_[0] and $_[0] eq __PACKAGE__ or
                        __blessed($_[0]) and $_[0]->isa(__PACKAGE__);

    my $v = shift;
    push @Exception_Stack, $@;
    return ref($v) eq 'ARRAY' ? @$v : $v if wantarray;
    return $v;
}


# Pop the exception on error stack. Stolen from Exception::Class::TryCatch
sub catch {
    # Can be used also as function
    my $self = shift if defined $_[0] and $_[0] eq __PACKAGE__ or
                        __blessed($_[0]) and $_[0]->isa(__PACKAGE__);

    my $want_object = 1;

    my $e;
    my $exception = @Exception_Stack ? pop @Exception_Stack : $@;
    if (__blessed($exception) and $exception->isa(__PACKAGE__)) {
        $e = $exception;
    }
    elsif ($exception eq '') {
        $e = undef;
    }
    else {
        my $class = ref $self || __PACKAGE__;
        $e = $class->new(message=>"$exception");
        $e->_collect_system_data;
    }
    if (scalar @_ > 0 and ref($_[0]) ne 'ARRAY') {
        $_[0] = $e;
        shift;
        $want_object = 0;
    }
    if (defined $e) {
        if (defined $_[0] and ref $_[0] eq 'ARRAY') {
            $e->throw() unless grep { $e->isa($_) } @{$_[0]};
        }
    }
    return $want_object ? $e : defined $e;
}


# Collect system data and fill the attributes and caller stack.
sub _collect_system_data {
    my $self = shift;

    $self->{time}  = CORE::time();
    $self->{pid}   = $$;
    $self->{tid}   = Thread->self->tid if defined &Thread::tid;
    $self->{uid}   = $<;
    $self->{euid}  = $>;
    $self->{gid}   = $(;
    $self->{egid}  = $);

    my $verbosity = defined $self->{verbosity} ? $self->{verbosity} : $self->{defaults}->{verbosity};
    # Collect stack info only if verbosity is meaning
    if ($verbosity > 1) {
        my @caller_stack;
        my $pkg = __PACKAGE__;
        for (my $i = 1; my @c = do { package DB; caller($i) }; $i++) {
            next if $c[0] eq $pkg;
            push @caller_stack, [ @c[0 .. 7], @DB::args ];
            # Collect only one entry if verbosity is meaning
            last if $verbosity < 3;
        }
        $self->{caller_stack} = \@caller_stack;
    }

    return $self;
}


# Stringify caller backtrace. Stolen from Carp
sub _caller_backtrace {
    my $self = shift;
    my $i = 0;
    my $mess;

    my $tid_msg = '';
    $tid_msg = ' thread ' . $self->{tid} if $self->{tid};

    my %i = ($self->_caller_info($i));
    $i{file} = 'unknown' unless $i{file};
    $i{line} = 0 unless $i{line};
    $mess = " at $i{file} line $i{line}$tid_msg\n";

    while (my %i = $self->_caller_info(++$i)) {
        $mess .= "\t$i{wantarray}$i{sub_name} called at $i{file} line $i{line}$tid_msg\n";
    }

    return $mess;
}


# Return info about caller. Stolen from Carp
sub _caller_info {
    my $self = shift;
    my $i = shift;
    my %call_info;
    my @call_info = ();

    @call_info = @{ $self->{caller_stack}->[$i] }
        if defined $self->{caller_stack} and defined $self->{caller_stack}->[$i];

    @call_info{
        qw(pack file line sub has_args wantarray evaltext is_require)
    } = @call_info[0..7];

    unless (defined $call_info{pack}) {
        return ();
    }

    my $sub_name = $self->_get_subname(\%call_info);
    if ($call_info{has_args}) {
        my @args = map {$self->_format_arg($_)} @call_info[8..$#call_info];
        my $max_arg_nums = defined $self->{max_arg_nums} ? $self->{max_arg_nums} : $self->{defaults}->{max_arg_nums};
        if ($max_arg_nums > 0 and $#args+1 > $max_arg_nums) {
            $#args = $max_arg_nums - 2;
            push @args, '...';
        }
        # Push the args onto the subroutine
        $sub_name .= '(' . join (', ', @args) . ')';
    }
    $call_info{file} = 'unknown' unless $call_info{file};
    $call_info{line} = 0 unless $call_info{line};
    $call_info{sub_name} = $sub_name;
    $call_info{wantarray} = $call_info{wantarray} ? '@_ = ' : '$_ = ';
    return wantarray() ? %call_info : \%call_info;
}


# Figures out the name of the sub/require/eval. Stolen from Carp
sub _get_subname {
    my $self = shift;
    my $info = shift;
    if (defined($info->{evaltext})) {
        my $eval = $info->{evaltext};
        if ($info->{is_require}) {
            return "require $eval";
        }
        else {
            $eval =~ s/([\\\'])/\\$1/g;
            return
                "eval '" .
                $self->_str_len_trim($eval, defined $self->{max_eval_len} ? $self->{max_eval_len} : $self->{defaults}->{max_eval_len}) .
                "'";
        }
    }
    return ($info->{sub} eq '(eval)') ? 'eval {...}' : $info->{sub};
}


# Transform an argument to a function into a string. Stolen from Carp
sub _format_arg {
    my $self = shift;
    my $arg = shift;

    return 'undef' if not defined $arg;

    # Be careful! Do not recurse with our stringify!
    return '"' . overload::StrVal($arg) . '"' if ref $arg;

    $arg =~ s/\\/\\\\/g;
    $arg =~ s/"/\\"/g;
    $arg =~ s/`/\\`/g;
    $arg = $self->_str_len_trim($arg, defined $self->{max_arg_len} ? $self->{max_arg_len} : $self->{defaults}->{max_arg_len});

    $arg = "\"$arg\"" unless $arg =~ /^-?[\d.]+\z/;

    use utf8;  #! TODO: should be here?
    if (defined $utf8::VERSION and utf8::is_utf8($arg)) {
        $arg = join('', map { $_ > 255
            ? sprintf("\\x{%04x}", $_)
            : chr($_) =~ /[[:cntrl:]]|[[:^ascii:]]/
                ? sprintf("\\x{%02x}", $_)
                : chr($_)
        } unpack("U*", $arg));
    }
    else {
        $arg =~ s/([[:cntrl:]]|[[:^ascii:]])/sprintf("\\x{%02x}",ord($1))/eg;
    }

    return $arg;
}


# If a string is too long, trims it with ... . Stolen from Carp
sub _str_len_trim {
    my $self = shift;
    my $str = shift;
    my $max = shift || 0;
    if ($max > 2 and $max < length($str)) {
        substr($str, $max - 3) = '...';
    }
    return $str;
}


# Check if scalar is blessed. This is function, not a method!
eval "use Scalar::Util 'blessed';";
if (defined &Scalar::Util::blessed) {
    # Use faster XS version of blessed if available
    *__blessed = \&Scalar::Util::blessed;
}
else {
    eval << 'END';

    # Universal method for __blessed(). Stolen from Scalar::Util
    sub UNIVERSAL::Exception__a_sub_not_likely_to_be_here {
        return ref($_[0]);
    }

    # Pure Perl implementation of blessed function. Stolen from Scalar::Util
    sub __blessed ($) {
        local($@, $SIG{__DIE__}, $SIG{__WARN__});
        return length(ref($_[0]))
            ? eval { $_[0]->Exception__a_sub_not_likely_to_be_here }
            : undef;
    }
END
}

1;


=head1 IMPORTS

=over

=item use Exception qw[catch try];

Exports the B<catch> and B<try> functions to the caller namespace.

  use Exception qw[catch try];
  try eval { throw Exception; };
  if (catch my $e) { warn "$e"; }

=item use Exception 'I<Exception>', ...;

Creates the exception class automatically at compile time.  The newly created
class will be based on Exception class.

  use Exception qw[Exception::Custom Exception::SomethingWrong];
  throw Exception::Custom;

=item use Exception 'I<Exception>' => { isa => I<BaseException>, version => I<version> };

Creates the exception class automatically at compile time.  The newly created
class will be based on given class and has the given $VERSION variable.

  use Exception
    'try', 'catch',
    'Exception::IO',
    'Exception::FileNotFound' => { isa => 'Exception::IO' },
    'Exception::My' => { version => 0.2 };
  try eval { throw Exception::FileNotFound; };
  if (catch my $e) {
    if ($e->isa('Exception::IO')) { warn "can be also FileNotFound"; }
    if ($e->isa('Exception::My')) { print $e->VERSION; }
  }

=item no Exception qw[catch try];

=item no Exception;

Unexports the B<catch> and B<try> functions from the caller namespace.

  use Exception qw[try catch];
  try eval { throw Exception::FileNotFound; };  # ok
  no Exception;
  try eval { throw Exception::FileNotFound; };  # syntax error

=back

=head1 CONSTANTS

=over

=item FIELDS

Declaration of class fields as reference to hash.

The fields are listed as I<name> => {I<properties>}, where I<properties> is a
list of field properties:

=over

=item is

Can be 'rw' for read-write fields or 'ro' for read-only fields.

=item default

Optional property with the default value if the field value is not defined.

=back

The read-write fields can be set with B<new> constructor.  Read-only fields
are modified by Exception class itself and arguments for B<new> constructor
will be stored in B<properties> field.

The constant have to be defined in derivered class if it brings additional
fields.

  package Exception::My;
  our $VERSION = 0.1;
  use base 'Exception';

  # Define new class fields
  use constant FIELDS => {
    %{Exception->FIELDS},       # base's fields have to be first
    readonly  => { is=>'ro', default=>'value' },  # new ro field
    readwrite => { is=>'rw' },                    # new rw field
  };

  package main;
  try Exception eval {
    throw Exception::My readonly=>1, readwrite=>2;
  };
  if (catch Exception my $e) {
    print $e->{readwrite};                # = 2
    print $e->{properties}->{readonly};   # = 1
    print $e->{defaults}->{readwrite};    # = "value"
  }

=back

=head1 FIELDS

Class fields are implemented as values of blessed hash.

=over

=item message (rw, default: 'Unknown exception')

Contains the message of the exception.  It is the part of the string
representing the exception object.

  eval { throw Exception message=>"Message", tag=>"TAG"; };
  print $@->{message} if $@;

=item properties (ro)

Contains the additional properies of the exception.  They can be later used
with "with" method.

  eval { throw Exception message=>"Message", tag=>"TAG"; };
  print $@->{properties}->{tag} if $@;

=item verbosity (rw, default: 3)

Contains the verbosity level of the exception object.  It allows to change
the string representing the exception object.  There are following levels of
verbosity:

=over 2

=item 0

 Empty string

=item 1

 Message

=item 2

 Message at %s line %d.

The same as the standard output of die() function.

=item 3

 Class: Message at %s line %d
         %c_ = %s::%s() called at %s line %d
 ...

The output contains full trace of error stack.  This is the default option.

=back

If the verbosity is undef, then the default verbosity for exception objects
is used.

If the verbosity set with constructor (B<new> or B<throw>) is lower that 3,
the full stack trace won't be collected.

=item time (ro)

Contains the timestamp of the thrown exception.

  eval { throw Exception message=>"Message"; };
  print scalar localtime $@->{time};

=item pid (ro)

Contains the PID of the Perl process at time of thrown exception.

  eval { throw Exception message=>"Message"; };
  kill 10, $@->{pid};

=item tid (ro)

Constains the tid of the thread or undef if threads are not used.

=item uid (ro)

=item euid (ro)

=item gid (ro)

=item egid (ro)

Contains the real and effective uid and gid of the Perl process at time of
thrown exception.

=item caller_stack (ro)

If the verbosity on throwing exception was greater that 1, it contains the
error stack as array of array with informations about caller functions.  The
first 8 elements of the array's row are the same as first 8 elements of the
output of caller() function.  Further elements are optional and are the
arguments of called function.

  eval { throw Exception message=>"Message"; };
  ($package, $filename, $line, $subroutine, $hasargs, $wantarray,
  $evaltext, $is_require, @args) = $@->{caller_stack}->[0];

=item max_arg_len (rw, default: 64)

Contains the maximal length of argument for functions in backtrace output.
Zero means no limit for length.

  sub a { throw Exception max_arg_len=>5 }
  a("123456789");

=item max_arg_nums (rw, default: 8)

Contains the maximal number of arguments for functions in backtrace output.
Zero means no limit for arguments.

  sub a { throw Exception max_arg_nums=>1 }
  a(1,2,3);

=item max_eval_len (rw, default: 0)

Contains the maximal length of eval strings in backtrace output.  Zero means
no limit for length.

  eval "throw Exception max_eval_len=>10";
  print "$@";

=item defaults (rw)

Meta-field contains the list of default values.

  my $e = new Exception;
  print defined $e->{verbosity}
    ? $e->{verbosity}
    : $e->{defaults}->{verbosity};

=back

=head1 CONSTRUCTORS

=over

=item new([%I<args>])

Creates the exception object, which can be thrown later.  The system data
fields like B<time>, B<pid>, B<uid>, B<gid>, B<euid>, B<egid> are not filled.

If the key of the argument is read-write field, this field will be filled. 
Otherwise, the properties field will be used.

  $e = new Exception message=>"Houston, we have a problem",
                     tag => "BIG";
  print $e->{message};
  print $e->{properties}->{tag};

The constructor reads the list of class fields from FIELDS constant function
and stores it in the internal cache for performance reason.  The defaults
values for the class are also stored in internal cache.

=item throw([%I<args>]])

Creates the exception object and immediately throws it with die() function.

  open FILE, $file
    or throw Exception message=>"Can not open file: $file";

=back

=head1 METHODS

=over

=item throw([$I<exception>])

Immediately throws exception object with die() function.  It can be used as
for throwing new exception as for rethrowing existing exception object.

  eval { throw Exception message=>"Problem", tag => "TAG"; };
  # rethrow, $@ is an exception object
  $@->throw if $@->{properties}->{tag} eq "TAG";

=item stringify([$I<verbosity>[, $I<message>]])

Returns the string representation of exception object.  It is called
automatically if the exception object is used in scalar context.  The method
can be used explicity and then the verbosity level can be used.

  eval { throw Exception; };
  $@->{verbosity} = 1;
  print "$@";
  print $@->stringify(3) if $VERY_VERBOSE;

=item with(I<condition>)

Checks if the exception object matches the given condition.  If the first
argument is single value, the B<message> attribute will be matched.  If the
argument is a part of hash, the B<properties> attribute will be matched or
the attribute of the exception object if the B<properties> attribute is not
defined.

  $e->with("message");
  $e->with(tag=>"property");
  $e->with("message", tag=>"and the property");
  $e->with(tag1=>"property", tag2=>"another property");
  $e->with(uid=>0);
  $e->with(message=>'$e->{properties}->{message} or $e->{message}');

The argument (for message or properties) can be simple string or code
reference or regexp.

  $e->with("message");
  $e->with(sub {/message/});
  $e->with(qr/message/);

=item try(I<eval>)

The "try" method or function can be used with eval block as argument.  Then
the eval's error is pushed into error stack and can be used with "catch"
later.

  try Exception eval { throw Exception; };
  eval { die "another error messing with \$@ variable"; };
  catch Exception my $e;

The "try" returns the value of the argument in scalar context.  If the
argument is array reference, the "try" returns the value of the argument in
array context.

  $v = try Exception eval { 2 + 2; }; # $v == 4
  @v = try Exception [ eval { (1,2,3); }; ]; # @v = (1,2,3)

The "try" can be used as method or function.

  try Exception eval { throw Exception "method"; };
  Exception::try eval { throw Exception "function"; };
  Exception->import('try');
  try eval { throw Exception "exported function"; };

=item catch($I<exception>)

The exception is popped from error stack (or B<$@> variable is used if stack
is empty) and the exception is written into the method argument.

  eval { throw Exception; };
  catch Exception my $e;
  print $e->stringify(1);

If the B<$@> variable does not contain the exception object but string, new
exception object is created with message from B<$@> variable.

  eval { die "Died\n"; };
  catch Exception my $e;
  print $e->stringify;

The method returns B<1>, if the exception object is caught, and returns B<0>
otherwise.

  eval { throw Exception; };
  if (catch Exception my $e) {
    warn "Exception caught: " . ref $e;
  }

If the method argument is missing, the method returns the exception object.

  eval { throw Exception; };
  my $e = catch Exception;

=item catch([$I<exception>,] \@I<ExceptionClasses>)

The exception is popped from error stack (or $@ variable is used if stack is
empty).  If the exception is not based on one of the class from argument, the
exception is thrown immediately.

  eval { throw Exception::IO; }
  catch Exception my $e, ['Exception::IO'];
  print "Only IO exception was caught: " . $e->stringify(1);

=back

=head1 PRIVATE METHODS

=over

=item _collect_system_data

Collect system data and fill the attributes of exception object.  This method
is called automatically if exception if thrown.  It can be used by derived
class.

  package Exception::Special;
  use base 'Exception';
  use constant FIELDS => {
    %{Exception->FIELDS},
    'special' => { is => 'ro' },
  };
  sub _collect_system_data {
    my $self = shift;
    $self->SUPER::_collect_system_data(@_);
    $self->{special} = get_special_value();
    return $self;
  }

Method returns the reference to the self object.

=back

=head1 SEE ALSO

There are more implementation of exception objects available on CPAN:

=over

=item L<Error>

Complete implementation of try/catch/finally/otherwise mechanism.  Uses
nested closures with a lot of syntactic sugar.  It is slightly faster than
Exception module.  It doesn't provide a simple way to create user defined
exceptions.  It doesn't collect system data and stack trace on error.

=item L<Exception::Class>

More perl-ish way to do OO exceptions.  It is too heavy and too slow.  It
requires non-core perl modules to work.  It missing try/catch mechanism.

=item L<Exception::Class::TryCatch>

Additional try/catch mechanism for L<Exception::Class>.  It is also slow as
L<Exception::Class>.

=item L<Class::Throwable>

Elegant OO exceptions without try/catch mechanism.  It might be missing some
features found in Exception and L<Exception::Class>.

=item L<Exceptions>

Not recommended.  Abadoned.  Modifies %SIG handlers.

=back

See also L<Exception::System> class as an example for implementation of
echanced exception class based on this Exception class.

=head1 PERFORMANCE

The Exception module was benchmarked with other implementation.  The results
are following:

=over

=item pure eval/die with string

504122/s

=item pure eval/die with object

165414/s

=item Exception module with default options

6338/s

=item Exception module with verbosity = 1

16746/s

=item L<Error> module

17934/s

=item L<Exception::Class> module

1569/s

=item L<Exception::Class::TryCatch> module

1520/s

=item L<Class::Throwable> module

7587/s

=back

The Exception module is 80 times slower than pure eval/die.  This module was
written to be as fast as it is possible.  It does not use i.e. accessor
functions which are slow about 6 times than standard variable.  It is slower
than pure die/eval because it is object oriented by its design.  It can be a
litte faster if some features, as stack trace, are disabled.

=head1 BUGS

The module was tested with L<Devel::Cover> and L<Devel::Dprof>.

If you find the bug, please report it.

=head1 AUTHORS

Piotr Roszatycki E<lt>dexter@debian.orgE<gt>

=head1 COPYRIGHT

Copyright 2007 by Piotr Roszatycki E<lt>dexter@debian.orgE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>
