package Exception;

use strict;
use vars qw($VERSION @ISA @EXPORT_OK);

require Exporter;

@ISA       = qw(Exporter);
@EXPORT_OK = qw( try throw catch rethrow );
$VERSION   = '1.00';

# Preloaded methods go here.

#
# throw( new Exception('Something really bad happened!',"\n") );
#
sub new
{
  my $this  = shift;
  my $class = ref($this) || $this;
  my $self  = {};

  bless $self,$class;
  my($p,$f,$l) = caller();
  $self->_exception__capture_exception_information($p,$f,$l,@_);
  return $self;
}

sub _exception__capture_exception_information
{
  my $self     = shift;
  my $p        = shift;  # package
  my $f        = shift;  # filename
  my $l        = shift;  # line number
  $self->package($p);
  $self->filename($f);
  $self->line($l);
  $self->when(scalar(localtime()));
  $self->error(join('',@_));
  $self->stacktrace(
    $self->stacktrace_to_string($self->get_stacktrace())
  );
  return 1;
}

#
# this captures a 'live' stacktrace -- when it's called
#
sub get_stacktrace
{
  my $self = shift;
  my $i    = 0;
  my @stack;

  while(1) {
    my @info = caller($i++);
    last unless @info;
    push @stack, [@info];
  }

  return @stack;
}

sub stacktrace_to_string
{
  my $self = shift;
  my $s = '';

  foreach my $rframe (@_) {
    $s .= sprintf("  STACKTRACE: [%s] %s(%s)->%s hasargs:%s\n", @{$rframe});
  }

  return $s;
}

#
# print 'Line number: ',$e->line(),"\n";
#
sub line
{
  my $self = shift;
  if(@_) { $self->{'line'} = shift; }
  return $self->{'line'};
}

#
# print 'Package name: ',$e->package(),"\n";
#
sub package
{
  my $self = shift;
  if(@_) { $self->{'package'} = shift; }
  return $self->{'package'};
}

#
# print 'In File: ',$e->filename(),"\n";
#
sub filename
{
  my $self = shift;
  if(@_) { $self->{'filename'} = shift; }
  return $self->{'filename'};
}

#
# print 'Raw stacktrace: ',"\n",$e->stacktrace(),"\n";
#
sub stacktrace
{
  my $self = shift;
  if(@_) { $self->{'stacktrace'} = shift; }
  return $self->{'stacktrace'};
}

#
# print 'The error was: ',$e->error(),"\n";
#
sub error
{
  my $self = shift;
  if(@_) { $self->{'error'} = shift; }
  return $self->{'error'};
}

#
# print 'It happened at: ',$e->when(),"\n";
#
sub when
{
  my $self = shift;
  if(@_) { $self->{'when'} = shift; }
  return $self->{'when'};
}

#
# try {
#   open FILE, '</not/a/file/' or throw(new Exception('Error: ',$!,"\n"));
# };
#
sub try (&)
{
  my $try = shift;
  eval { &$try };
}

#
# print 'Exception summary: ',"\n",$e->as_string(),"\n";
#
sub as_string
{
  my $self = shift;
  my $s    = '';
  $s .= 'Exception:    ' . $self->error()   . "\n";
  $s .= '  in package: ' . $self->package() . "\n";
  $s .= '  in file:    ' . $self->filename(). "\n";
  $s .= '  at line:    ' . $self->line()    . "\n";
  $s .= '  at time:    ' . $self->when()    . "\n";
  $s .= $self->stacktrace();

  return $s;
}

#
# if(catch(qw(Exception e))) {
#   die 'Exception: ',"\n",$e->as_string(),"\n";
# }
# if(catch()) {
#   die 'Unknown exception: ',$@,"\n";
# }
#
sub catch
{
  return undef unless $@;             # nothing to catch
  return 1     unless @_;             # $@ exists, but no type to check for...
  my $type = shift;                   # grab the type
  return undef unless ref($@);        # not an object?
  return undef unless $@->isa($type); # not a $type object?

  my $name = shift;                   # name to export to 
  return 1 unless $name;

  my $p    = (caller)[0]||'main';     # determine the caller's package:
  my $e    = $@;                      # create the variable in their package...
  my $code = sprintf('$%s::%s = $e',$p,$name);
  eval $code;                         # this should export the symbol
  $@ = undef;                         # clear the exception
  return 1;
}

#
# throw(Exception->new('Error: ',$!,"\n"));
# throw(new Exception('Error: ',$!,"\n"));
#
sub throw (@) { die @_; }
sub rethrow { die @_||$@; }

# Autoload methods go after =cut, and are processed by the autosplit program.

1;
__END__
# Below is the stub of documentation for your module. You better edit it!

=head1 NAME

Exception - Exception handling and a base exception class.

=head1 SYNOPSIS

  use Exception qw(try catch throw);

  try { throw(new Exception('Error.')); };
  if(catch(qw(Exception e))) { 
    print 'Caught: ',$e->as_string(),"\n";
  }
  elsif(catch()) {
    print 'Caught Unknown: ',$@,"\n";
  }

=head1 DESCRIPTION

Exception handling routines.  Execute try blocks, throw exceptions and 
catch them.  This module also provides a base exception object.

=head1 API REFERENCE

=head2 new

  throw(new Exception('Error: ',$!));

Construct a new exception object.  During construction, the object will
capture the caller's state information, including a stacktrace by using
the caller() function.

=head2 _exception__capture_exception_information

this is an internal function called by new() that actualy does the work
of capturing the stacktrace and other state information.  The information
is then stored into the exception object.

=head2 get_stacktrace

  my @stack = Exception->get_stacktrace();

This method is called by _exception__capture_exception_information() during
construction to capture the stacktrace.  It returns an array of array
references that represents the captured stacktrace.  It can be invoked
either as a method on an exception object, or as a package method (as the
example above shows).

=head2 stacktrace_to_string

  print "Stacktrace:\n",Exception->stacktrace_to_string(@stack),"\n";
  # or
  print "Stacktrace:\n",$e->stacktrace_to_string(@stack),"\n";

This method takes an array of array references and turns them into a 
stringified summary that's nicer looking than the raw data structure.

=head2 line

  print 'At line: ',$e->line(),"\n";

Get or set the line number in the exception object.

=head2 package

  print 'In pacakge: ',$e->pacakge(),"\n";

Get or set the package name in the exception object.

=head2 filename

  print 'In File: ',$e->filename(),"\n";

Get or set the file name in the exception object.

=head2 stacktrace

  print 'Stacktrace: ',"\n",$e->stacktrace(),"\n";

This method returns (actualy, it's a get or set method) the 
stacktrace [string version creatd by stacktrace_to_string()].
By default, the stacktrace is generated and stored during the
construction of the exception object.

=head2 error

  print 'Error: ',$e->error(),"\n";

Get or set the error in the exception object.

=head2 when

  print 'Hapened at: ',$e->when(),"\n";

Get or set the time in the exception object.

=head2 try

  try {
    ...
  };

Try a bock of code.  This function is really just a synonym for
eval, it's main reason for being here is to emulate the look of
the code from other languages that support exception handling (like
C++).  Please note that try is actualy a function which expects to be
passed a codeblock - this means that you need to follow your closing 
curly brace with a semicolon.

=head2 as_string

  print 'Exception: ',"\n",$e->as_string(),"\n";

Returns a nice looking summary of the inforamtion contained in the
exception object.

=head2 catch

  if(catch(qw(My::Exception e))) {
    print 'Caught My::Exception object: ',$e->as_string(),"\n";
  }
  elsif(catch(qw(Exception e))) {
    print 'Caught Exception object: ',$e->as_string(),"\n";
  }
  elsif(catch()) {
    print 'Caught old style or unknown type of exception: ',$@,"\n";
  }

Try catching an exception.  catch() expects its first argument to
be a class name.  If the exception that was thrown is of that type,
or of a type derived from the given type, catch() will return a true
value.  If the exception is not an object of the given type, catch()
will return undef.

If a second argument is passed to catch(), it will be assumed that 
it is to be a named scalar to store the exception object in.  catch()
will then create that symbol in the caller's namespace and assign the
exception object to it.  You don't have to use this, but if you do,
$@ will be cleared (set to undef) so it doesn't accidentaly trigger 
any other code that might check $@.  If you don't pass a symbol name
here, you get to decide what to do with $@ (it will still contain the
exception - weather its an object or not).

When you invoke catch() with no arguments, it will return true or false
based on weather or not $@ is defined.  This is how you can perform 
a 'catch all' for any exception type that you're not explicitly looking
for.

=head2 throw

  unless(open(FILE,'</not/a/file')) {
    throw(new Exception('Errror opening file: ',$!,"\n"));
  }

Throw a new exception.  throw() is technicaly just a synonym for 
Perl's die().

=head2 rethrow

  try {
    ...
  };
  if(catch(qw(Exception e))) {
    # handle the exception...
  }
  elsif(catch()) {
    # we don't know what this is...
    rethrow();
  }

rethrow() is mainly here for readability right now, though plans are 
to probably have the exceptoin object capture some kinds of information 
every time it's thrown or rethrown.  rethrow() currently is exactly the
same as throw() which is bacily just a synonym for die.

Called with no arguments, rethrow() throws $@.  Called with an argument,
rethrow() throws it's arguments.

=head1 DERIVING NEW EXCEPTION TYPES

Usualy the type of the exception is all that's importiant, so actualy
deriving a new object from Exception and overriding behavior isn't
commonly done.  So, for Perl to recognize the new class type, all 
that really needs to be set up is the ISA array.  So, all you will
have to do is:

  @Test::Exception::ISA = qw(Exception);

Then use the new type:

  try {
    ...
  };
  if(catch(qw(Test::Exception e))) {
    # caught a Test::Exception...
  }
  elsif(catch(qw(Exception e))) {
    # caught an Exception...
  }
  elsif(catch()) {
    # caught something else...
  }

=head1 AUTHOR

Kyle R. Burton <mortis@voicenet.com>

=head1 SEE ALSO

perl(1).

=cut
