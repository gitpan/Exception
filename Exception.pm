# $Id: Exception.pm,v 1.4 2001/04/05 11:14:23 pete Exp $

# Exception handling module for Perl - docs are after __END__

# Copyright (c) 1999-2001 Horus Communications Ltd. All rights reserved.
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.

package Exception;

($VERSION)=q$Revision: 1.4 $=~m/Revision:\s+([^\s]+)/;

require Exporter;
@ISA=qw(Exporter);

@EXPORT_OK=qw(
  DEBUG_NONE DEBUG_CONTEXT DEBUG_STACK DEBUG_ALL
  FRAME_PACKAGE FRAME_FILE FRAME_LINE FRAME_SUBNAME
  FRAME_HASARGS FRAME_WANTARRAY FRAME_LAST
  try when except reraise finally confessor
);

%EXPORT_TAGS=(
  all    => \@EXPORT_OK,
  stack  => [qw(try when except reraise finally
		FRAME_PACKAGE FRAME_FILE FRAME_LINE FRAME_SUBNAME
		FRAME_HASARGS FRAME_WANTARRAY FRAME_LAST)],
  debug  => [qw(try when except reraise finally
		DEBUG_NONE DEBUG_CONTEXT DEBUG_STACK DEBUG_ALL)],
  try    => [qw(try when except reraise finally)]
);


use 5.005;
use strict;

use vars qw(
  $mod_perl
  $initialised
  $default
  $oldHandler
);

use constant DEBUG_NONE      => 0;
use constant DEBUG_CONTEXT   => 1;
use constant DEBUG_STACK     => 2;
use constant DEBUG_ALL       => 3;

use constant FRAME_PACKAGE   => 0;
use constant FRAME_FILE      => 1;
use constant FRAME_LINE      => 2;
use constant FRAME_SUBNAME   => 3;
use constant FRAME_HASARGS   => 4;
use constant FRAME_WANTARRAY => 5;
use constant FRAME_LAST      => 5;

use overload '""'=>sub {shift->text(2)};


sub _clone($);
sub _confess($$);


BEGIN {
  $mod_perl=$ENV{MOD_PERL};
  require Apache if $mod_perl;
  $oldHandler='DEFAULT';
  $initialised=0;
}


sub finalise() {
  $initialised=0;
}


sub initialise() {
  unless ($initialised) {
    $initialised=1;

    Apache->request->register_cleanup(\&finalise)
      if $mod_perl && exists $ENV{REQUEST_URI};

    $default=bless {TEXT=>[]}, 'Exception';
    $default->id('');
    $default->debugLevel($ENV{_DEBUG_LEVEL} || 0);
    $default->confessor([\&_confess]);
    $default->exitcode(1);
  }

  $default
}


sub _blessed($) {
  my $data=shift;
  my $ref=ref $data;
  my $blessed=$ref && eval {$data->isa('UNIVERSAL')};
  return ('', $ref) unless $blessed;

  $data->isa($_) and return ($ref, $_)
    foreach qw(HASH ARRAY SCALAR CODE GLOB Regexp);

  ($ref, $ref)
}


sub _clone($) {
  my $data=shift;
  my ($blessed, $ref)=_blessed $data;
  return $data unless $ref;

  if ($ref eq 'HASH') {
    my %clone=map {$_=>_clone $data->{$_}} keys %$data;
    $blessed ? bless \%clone, $blessed : \%clone
  } elsif ($ref eq 'ARRAY') {
    my @clone=map {_clone $_} @$data;
    $blessed ? bless \@clone, $blessed : \@clone
  } elsif ($ref eq 'SCALAR') {
    my $clone=$$data;
    $blessed ? bless \$clone, $blessed : \$clone
  } else {
    $data
  }
}


sub _isError($) {
  my $error=shift;
  ref $error && eval {$error->isa('Exception')}
}


sub _handler {
  my $error=shift;
  initialise unless $initialised;

  if (_isError $error) {
    $error->raise(@_);
  } else {
    my $text=join '', $error, @_;
    $text=~tr/\f\n\t\r / /s;
    $text=~s/^ ?(.*?) ?$/$1/;
    $text=~s/^\[.*?\] \w*: ?//;
    $text=~s/ ?at [\w\/\.\-]+ line \d+(\.$)?//;
    Exception->raise($text, {ID=>'die'});
  }
}


sub _confess($$) {
  my ($error, $quiet)=@_;
  print STDERR (scalar $error->text(2)) unless $quiet;
  $quiet
}


sub _frameMatch($$) {
  my ($a, $b)=@_;

  foreach (0..FRAME_LAST) {
    my ($aa, $bb)=($a->[$_], $b->[$_]);
    (defined $aa xor defined $bb) and return 0;
    defined $aa && $aa ne $bb and return 0;
  }

  1
}


sub _stackmerge($$) {
  my ($error, $stack)=@_;
  my $oldStack=$error->{STACK};
  my @stack=@$stack;

  if ($oldStack) {
    my $oldPtr=@$oldStack;
    my $newPtr=@stack;

    1 while
      --$oldPtr>=0 && --$newPtr>=0 &&
      _frameMatch $oldStack->[$oldPtr], $stack[$newPtr];

    unshift @stack, @$oldStack[0..$oldPtr]
      if $oldPtr>=0;

  }

  $error->{STACK}=\@stack;
}


sub new($$;$$) {
  my ($class, $id, $text, $extras)=@_;
  $class=initialise unless _isError $class;
  my $error=_clone $class;
  $error->{ID}=$id;

  if (defined $text) {
    if (ref $text eq 'HASH') {
      $extras=$text;
    } else {
      $error->{TEXT}=[$text];
    }

    if (ref $extras eq 'HASH') {
      foreach (keys %$extras) {
	my $extra=$extras->{$_};

	if (m/^(TEXT|CONFESS)$/ && ref $extra ne 'ARRAY') {
	  $error->{$_}=[$extra];
	} else {
	  $error->{$_}=$extra;
	}
      }
    }
  }

  $error
}


sub raise($;$$) {
  my $class=shift;
  $class=initialise unless _isError $class;
  my $handler=$SIG{__DIE__};
  local $SIG{__DIE__}=$handler eq \&_handler ? $oldHandler : \&_handler;
  my $error=_clone $class;
  my $extras=shift;

  if (defined $extras) {
    unless (ref $extras eq 'HASH') {
      push @{$error->{TEXT}}, $extras;
      $extras=shift;
    }

    if (ref $extras eq 'HASH') {
      foreach (keys %$extras) {
	my $extra=$extras->{$_};

	if (m/^(TEXT|CONFESS)$/) {
	  push @{$error->{$_}}, $extra;
	} else {
	  $error->{$_}=$extra;
	}
      }
    }
  }

  my $debug=$error->{DEBUGLEVEL};

  if ($debug) {
    my ($stack, @stack)=0;

    # the pending flag is a bit of magic for DEBUG_CONTEXT - we don't want
    # a stack entry added for reraise, but we *do* want one for die, so if
    # we have an internal raise, we check if the first external frame is for
    # a die (our $SIG{__DIE__} _handler)
    my $pending=0;

    while (my @frame=caller $stack++) {
      if ($frame[FRAME_PACKAGE] eq 'Exception') {
	$pending=1
	  if $debug==DEBUG_CONTEXT &&
	     $frame[FRAME_SUBNAME] eq 'Exception::raise';

	next if $debug!=DEBUG_ALL;
      }

      $frame[FRAME_SUBNAME]=$1 eq '_handler' ? '[die]' : "[$1]"
	if $frame[FRAME_SUBNAME]=~m/^Exception::(.*)$/;

      push @stack, [@frame[0..FRAME_LAST]]
	if $pending==0 || $frame[FRAME_SUBNAME] eq '[die]';

      last if $debug==DEBUG_CONTEXT;
    }

    $error->_stackmerge(\@stack);
  }

  die $error;
}


sub as($$) {
  my ($error, $template)=@_;

  if (_isError $template) {
    $error->id($template->id);
    $error->debugLevel($template->debugLevel);
    $error->confessor($template->confessor);
    bless $error, ref $template;
  } else {
    $error->id($template);
  }

  $error
}


sub text($;$) {
  my ($error, $option)=@_;
  $option||=0;
  my $text=$error->{TEXT};
  my $stack=$error->{STACK};
  wantarray and return $option<2 ? @$text : (@$text, $stack);
  $option==1 and return join "\n", @$text;
  $option==0 || !$stack || !@$stack and return join '', map {"$_\n"} @$text;

  join '',
    (map {"$_\n"} @$text),
    "\nStack trace:\n",
    map {
      (" $_->[FRAME_PACKAGE] \t$_->[FRAME_FILE] \t",
       "line $_->[FRAME_LINE] \t$_->[FRAME_SUBNAME]\n")
    } @$stack

}


sub stack($) {
  my $error=shift;
  $error->{STACK}
}


sub debugLevel($;$) {
  my ($error, $newLevel)=@_;
  $error=initialise unless _isError $error;
  my $oldLevel=$error->{DEBUGLEVEL};
  $error->{DEBUGLEVEL}=$newLevel if defined $newLevel;
  $oldLevel
}


sub id($;$) {
  my ($error, $newId)=@_;
  $error=initialise unless _isError $error;
  my $oldId=$error->{ID};
  $error->{ID}=$newId if defined $newId;
  $oldId
}


sub exitcode($;$) {
  my ($error, $newCode)=@_;
  $error=initialise unless _isError $error;
  my $oldCode=$error->{CODE};
  $error->{CODE}=$newCode if defined $newCode;
  $oldCode
}


sub confessor($;&) {
  my ($error, $code)=@_;
  my $replace=ref $code eq 'ARRAY';

  if (_isError $error) {
    $code=$default->confessor if $replace && !@$code;
  } else {
    $error=initialise;
    $code=[\&_confess] if $replace && !@$code;
  }

  my $old=$error->{CONFESS};

  if ($replace) {
    $error->{CONFESS}=$code;
  } elsif ($code) {
    push @{$error->{CONFESS}}, $code;
  }

  $old
}


sub confess($) {
  my $error=shift;
  my $quiet=0;

  foreach (reverse @{$error->{CONFESS}}) {
    next unless ref $_ eq 'CODE';
    $quiet=&$_($error, $quiet);
    $quiet=0 unless defined $quiet;
    last if $quiet<0;
  }
}


sub croak($;$) {
  my ($error, $exitcode)=@_;
  $exitcode=$error->exitcode unless defined $exitcode;
  $error->confess;
  exit $exitcode;
}


sub _matches($@) {
  my $error=shift;

  foreach (@_) {
    my $ref=ref $_;

    if ($ref eq 'Regexp') {
      $error->text=~$_ and return 1;
    } elsif (_isError $_) {
      ref $error eq $ref && $error->{ID} eq $_->{ID} and return 1;
    } else {
      $error->id eq $_ and return 1;
    }
  }

  0
}


sub try(&;$) {
  my ($try, $actions)=@_;
  initialise unless $initialised;
  my $retval=eval {&$try};
  my $error=$@;
  my $propagate;

  if ($error) {
    $SIG{__DIE__}=\&_handler;
    my $except=$actions->{EXCEPT};

    unless ($except) {
      $propagate=$error;
      goto FINALLY;
    }

    my @default;
    my $matched=0;

    foreach (reverse @$except) {
      my $code=shift @$_;

      if (@$_) {
	if ($error->_matches(@$_)) {
	  unless ($code) {
	    $propagate=$error;
	    goto FINALLY;
	  }

	  $retval=eval {&$code($error, $retval)};

	  if ($@) {
	    $propagate=$@;
	    goto FINALLY;
	  }

	  $matched=1;
	}
      } elsif (!$matched) {
	push @default, $code;
      }
    }

    unless ($matched) {
      unless (@default) {
	$propagate=$error;
	goto FINALLY;
      }

      foreach (@default) {
	unless ($_) {
	  $propagate=$error;
	  goto FINALLY;
	}

	$retval=eval{&$_($error, $retval)};

	if ($@) {
	  $propagate=$@;
	  goto FINALLY;
	}
      }
    }
  }

 FINALLY:
  my $finally=$actions->{FINALLY};

  if ($finally) {
    foreach (reverse @$finally) {
      $retval=eval{&$_($error, $retval)};

      if ($@) {
	if ($propagate) {
	  # ick... we have an exception in a finally block after either a
	  # reraise or an exception in an except block (or, indeed, an
	  # exception in an earlier finally block); merging the exceptions
	  # is the least bad course of action
	  push @{$propagate->{TEXT}}, $@->{TEXT};
	  $propagate->_stackmerge($@->{STACK});
	} else {
	  $propagate=$@;
	}
      }
    }
  }

  $propagate->raise if $propagate;
  $retval
}


sub when($$) {
  my ($match, $actions)=@_;
  my $except=$actions->{EXCEPT}[-1];
  push @$except, (ref $match eq 'ARRAY' ? @$match : $match);
  $actions
}


sub except(&;$) {
  my ($except, $actions)=@_;
  $actions||={};
  push @{$actions->{EXCEPT}}, [$except];
  $actions
}


sub reraise(;$) {
  my $actions=shift;
  $actions||={};
  push @{$actions->{EXCEPT}}, [undef];
  $actions
}


sub finally(&;$) {
  my ($finally, $actions)=@_;
  $actions||={};
  push @{$actions->{FINALLY}}, $finally;
  $actions
}


INIT {
  my $handler=$SIG{__DIE__} || 'DEFAULT';

  unless ($handler eq \&_handler) {
    $oldHandler=$handler;
    $SIG{__DIE__}=\&_handler;
  }
}


1

__END__

=head1 NAME

    Exception - structured exception handling for Perl

=head1 SYNOPSIS

    use Exception qw(:all);

    Exception->debugLevel(DEBUG_STACK);
    my $err=new Exception 'id';

    try {
      $err->raise('error text');
      die 'dead';
    } when $err, except {
        my $error=shift;
	$error->confess;
      }
      when 'die', reraise
      except {shift->croak}
      finally {
	print STDERR "Tidying up\n";
      };

=head1 DESCRIPTION

This module fulfils two needs; it converts all errors raised by I<die>
to exception objects which may contain stack trace information and it
implements a structured exception handling syntax as summarised above.

=head2 What You Get Just by Loading the Module

B<Exception> installs a C<$SIG{__DIE__}> handler that converts text
passed to I<die> into an exception object. Stringification for the object
is mapped onto the L<confess|"confess"> method which, by default, will simply print
the error text on to I<STDERR>.

=head2 Structured Exception Handling

B<Exception> allows you to structure your exception handling; code that
can directly or indirectly raise an exception is enclosed in a
L<try|"STRUCTURED EXCEPTION HANDLING"> block, followed by
L<except|"Trapping Exceptions"> blocks that can handle specific exceptions or
act as a catch-all handler for any exceptions not otherwise dealt with.
Exceptions may be propagated back to outer contexts with the possibility of
adding extra information to the exception, and a L<finally|"Finalisation Blocks">
block can also be specified, containing tidy-up code that will be called whether
or not an exception is raised.

Exception handling blocks can be tied to specific exceptions by id, by
exception object or by regexp match against error text. The default
exception display code can be augmented or replaced by user code.

=head2 Stack Tracing

B<Exception> can be persuaded to capture and display a stack trace
globally, by exception object or explicitly when an exception is raised.
You can capture just the context at which the exception is raised, a full
stack trace or an absolutely full stack trace including calls within the
B<Exception> module itself.

=head1 EXCEPTION OBJECTS

B<Exception> will create an exception object when it traps a I<die>. More
flexibly, user-created exception objects can be raised with the L<raise|"raise">
method.

Each exception object has an id; a text string that is set when the object
is created (and that can be changed using the L<id|"id"> method thereafter).
I<die> exceptions have the id 'die', anonymous exceptions created at
L<raise|"raise"> time have an empty id. The exception id is set initially by a
parameter to the exception constructor:

  my $err=new Exception 'id';

Exceptions are raised by the L<raise|"raise"> method:

  $err->raise('error text');

or:

  Exception->raise('text');

for an anonymous exception.

=head1 STRUCTURED EXCEPTION HANDLING

Code to be protected by B<Exception> is enclosed in a C<try {}> block. Any
I<die> or L<raise|"raise"> event is captured; what happens next is
up to you. In any case, you need to import the routines that implement the
exception structuring:

  use Exception qw(:try);

is the incantation. Either that or one of C<qw(:stack)>, C<qw(:debug)>
or C<qw(:all)> if you need stack frame, debug or both facilities as
well.

=head2 Default Behaviour

If no exception handling code is present, the exception is reraised and
thus passed to the calling block; this is, of course, exactly what would
happen if I<try> wasn't present at all. More usefully, the same will happen
for any exceptions raised that aren't matched by any of the supplied
exception blocks.

If no user-supplied exception handler gets called at all, Perl will
display the exception by stringifying it and terminate the program.

=head2 Trapping Exceptions

I<except> blocks match all or some exceptions. You can define as many as you
like; all blocks that specifically match an exception are called (unless an
earlier I<except> block raises an exception itself), default blocks are only
executed for otherwise unmatched exceptions.

In either case, the I<except> block is passed two parameters: the exception
object and the current return value for the entire I<try> construct if it
has been set.

Use the I<when> clause to match exceptions against I<except> blocks:

  try {<code>} when <condition>, except {<handler>};

Conditions may be text strings, matching the id of an exception, regexp
refs, matching the text of an exception, or exception objects, matching
the given exception object or clones thereof. Multiple conditions may be
specified in an array ref; the I<except> block will apply if any of the
conditions match.

For example:

  my $err=new Exception 'foo';

  try {
    $err->raise('bar');
  } when ['foo', qr/bar/, $err], except {
      shift->croak;
    };

will match on all three conditions.

=head2 Reraising Exceptions

Exceptions can be passed to a calling context by reraising them using the
I<reraise> clause. I<reraise> can be tied to specific exceptions using
I<when> exactly as for I<except>.

For example:

  try {
    <code>
  } when 'die', reraise
    except {
      <other exceptions>
    };

would pass exceptions raised by I<die> to the calling routine.

=head2 Transforming Exceptions

It is sometimes useful to change the id of an exception. For example, a
module might want to identify all exceptions raised within it as its own,
even if they were originally raised in another module that it called. The
L<as|"as"> method performs this function:

  my $myErr=new Exception 'myModule';

  try {
    <calls to other code that might raise exceptions>
    <local code that might raise $myErr exceptions>
  } when $myErr, reraise
    except {
      shift->as($myErr)->raise('extra text');
    };

This will pass locally raised exception straight on; other exceptions will
be converted to C<$myErr> exceptions first. The error text parameter to
the L<raise|"raise"> can be omitted: if so, the original error text is passed on
unchanged. Adding extra text can however be useful in providing extra
contextual information for the exception.

Using an exception object as the parameter to L<as|"as"> in this way replaces
the I<id>, I<debugLevel> and I<confessor> properties of the original
exception. L<as|"as"> can also be passed a text string if only the I<id> of the
exception needs changing.

=head2 Finalisation Blocks

One or more I<finally> blocks can be included. These will B<all> be executed
B<always> regardless of exceptions raised, trapped or reraised and can
contain any tidy-up code required - any exception raised in an I<except>
block, reraised or not handled at all will be raised B<after> all I<finally>
blocks have been executed:

  try {
    <code>
  } except {
      <exception handling>
    }
    finally {
      <housekeeping code>
    }

The I<finally> blocks are passed two parameters, the exception (if any) and
the current return value (if any) in the same way as for I<except> blocks.

=head2 Return Values

I<try> constructs can return a (scalar) value; this is the value returned
by either the I<try> block itself or by the last executed I<except> block if
any exception occurs, passed though any I<finally> blocks present.

For example:

  my $value=try {
    <code>
    return 1;
  } except {
      <code>
      return 0;
    }
    finally {
      my ($error, $retval)=@_;
      <code>
      return $retval;
    }

will set C<$value> to C<1> or C<0> depending on whether an exception has
occured. Note the way that the return value is passed through the
I<finally> block.

=head1 STACK TRACING

B<Exception> can be persuaded to capture and display a stack trace by
any one of four methods:

=over 4

=item 1.

by setting the environment variable C<_DEBUG_LEVEL> before starting your
Perl script.

=item 2.

by setting the package default with C<< Exception->debugLevel(DEBUG_STACK) >>.

=item 3.

by setting the debug level explicitly in an error object when you create
it:

  my $err=new Exception 'foo';
  $err->debugLevel(DEBUG_CONTEXT);

=item 4.

by setting the debug level when you raise the exception:

  $err->raise("failed: $!", {DEBUGLEVEL=>DEBUG_ALL});

=back

Each of these will override preceding methods. The default default is no
stack capture at all.

The debug level can be set to:

=over 4

=item DEBUG_NONE:

no stack trace is stored.

=item DEBUG_CONTEXT:

only the location at which the exception was raised is stored.

=item DEBUG_STACK:

a full stack trace, excluding calls within B<Exception>, is stored.

=item DEBUG_ALL:

a full stack trace, B<including> calls within B<Exception>, is stored.

=back

You need to import these constants to use them:

  use Exception qw(:debug);
  use Exception qw(:all);

will do the trick.

Note that these controls apply to when the exception is raised - the
display routines will always print or return whatever stack information
is available to them.

=head1 EXCEPTION OBJECT METHODS

=head2 new

  my $err=new Exception 'id', 'error text';
  my $new=$err->new('id2', 'error text');

This method either creates a new exception from scratch or clones an
existing exception.

The first parameter is an exception id that can be used to identify either
individual exceptions or classes of exceptions. The optional second
parameter sets the text of the exception, this can be added to when the
exception is raised. The default is no text.

=head2 raise

  open FH, "<filename"
    or $err->raise("can't read filename: $!");

Raise an exception. That's it really. If I<raise> is applied to an existing
exception object as above, the text supplied is added to any pre-existing
text in the object. Anonymous exceptions can also be raised:

  Exception->raise('bang');

but the use of predeclared exception objects is encouraged.

=head2 as

  $err1->as($err2);
  $err1->as('new id');

Transform an exception object either from another template exception, which
will change the object's id, debug level and confessor, or by name, which
will just change the id of the exception.

I<as> returns the exception object, so a further method (typically L<raise|"raise">)
may be applied in the same statement:

  $err1->as('foo')->raise;

=head2 text

  my $text=$err->text;
  my @text=$err->text;
  my $textAndStack=$err->text(2);

Return the text and, optionally, any saved stack trace of an exception object.
I<text> can take a parameter (which defaults to C<0>) and can be called in
scalar or list context:

  param  scalar                      list

  0      line1 \n line2 \n           (line1, line2)
  1      line1 \n line2              (line1, line2)
  2      line1 \n line2 \n stack \n  (line1, line2, stack)

Be careful about context: C<< print $err->text; >> probably won't do what you want;
you almost certainly meant C<< print scalar($err->text); >>.

An exception gains a line every time it is L<raise|"raise">d with a text parameter.
Actually, to be precise, L<raise|"raise"> creates a new exception object with the
extra line, but that's the sort of implementation detail you don't need to
know, unless of course you want to...

=head2 stack

  my $stack=$err->stack;

Return the stack trace data (if any) for an exception. The stack is returned
as a reference to an array of stack frames; each stack frame being a reference
to an array of data as returned by I<caller>. The stack frame elements can be
indexed symbolically as I<FRAME_PACKAGE>, I<FRAME_FILE>, I<FRAME_LINE>,
I<FRAME_SUBNAME>, I<FRAME_HASARGS> and I<FRAME_WANTARRAY>. I<FRAME_LAST> is
defined as the index of the last element of the frame array for convenience.

To use these names, you need to import their definitions:

  use Exception qw(:stack);
  use Exception qw(:all);

will do what you want.

=head2 debugLevel

  my $level=$err->debugLevel;
  my $defaultLevel=Exception->debugLevel;
  my $old=$err->debugLevel($new);
  my $oldDefault=Exception->debugLevel($newDefault);

Get or set the stack trace level for an exception of object or the package
default. See the L<section|"STACK TRACING"> above.

=head2 confessor

  my $code=$err->confessor;
  my $defaultCode=Exception->confessor;
  my $old=$err->confessor($new);
  my $oldDefault=Exception->confessor($new);

Get or set code to display an exception. The routines all return a reference
to an array of coderefs; the routines are called in sequence when an
exception's L<confess|"confess"> or L<croak|"croak"> methods are invoked.

If I<confessor> is passed a coderef, the code is added to the end of the
array (the routines are actually called last to first); if I<confessor> is
passed a reference to an array of coderefs, the array is B<replaced> by the
one given. As a special case, if the array given is empty, the set of confessor
routines is reset to the default.

A confessor routine is passed two parameters when called: the exception
object and a I<quiet> flag; if this is non-zero, the routine is expected not
to produce any output. The routine should return the new value of the flag:
C<0>, C<1> or C<-1>, the last telling B<Exception> to not call any further
display routines at all.

As a trivial example, here's the default routine provided:

  sub _confess($$) {
    my ($error, $quiet)=@_;
    print STDERR (scalar $error->text(2)) unless $quiet;
    $quiet
  }

=head2 id

  my $id=$err->id;
  my $defaultId=Exception->id;
  my $old=$err->id($new);
  my $oldDefault=Exception->id($new);

Get or set the id of an exception, or of the package default used for
anonymous exceptions. Exception ids can be of any scalar type - B<Exception>
uses text strings for those it generates internally ('die' for exceptions
raised from I<die> and, by default, '' for anonymous exceptions) - but you
can even use object references if you can think of something useful to do
with them, with the proviso that I<when> uses a simple C<eq> test to match
them; you'll need to overload C<eq> for your objects if you want anything
clever to happen.

=head2 exitcode

  my $exitcode=$err->exitcode;
  my $defaultExitcode=Exception->exitcode;
  my $old=$err->exitcode($new);
  my $oldDefault=Exception->exitcode($new);

Get or set the exit code returned to the OS by L<croak|"croak">. This defaults to
C<1>.

=head2 confess

  $err->confess;

Display the exception using the list of L<confessor|"confessor"> routines
it contains. By default, this will display the exception text followed by
the stack trace (if one exists) on I<STDERR>.

=head2 croak

  $err->croak;
  $err->croak($exitCode);

Call the exception's L<confess|"confess"> method and terminate. If no exit code is
supplied, exit with the exception's exit code as set by the L<exitcode|"exitcode">
method.

=head1 BUGS

The module can interact in unpredictable ways with other code that messes
with C<$SIG{__DIE__}>. It does its best to cope by keeping and propagating
to any I<die> handler that is defined when the module is initialised, but
no guarantees of sane operation are given.

I<finally> blocks are always executed, even if an exception is reraised or
an exception is raised in an I<except> block. No problem there, but this
raises the question of what to do if B<another> exception is raised in the
I<finally> block. At present B<Exception> merges the the second exception
into the first before reraising it, which is probably the best it can do,
so this probably isn't a bug after all. Whatever.

Need More Tests.

=head1 AUTHOR

Pete Jordan <pete@skydancer.org.uk>
http://www.skydancer.org.uk/

=cut
