# $Id: Exception.pm,v 1.7 2003/06/22 18:44:30 ramtops Exp $

# Exception handling module for Perl - docs are after __END__

# Copyright (c) 1999-2003 Horus Communications Ltd. All rights reserved.
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.

package Exception;

use 5.6.0;
use strict;
use warnings;

use vars
  qw($VERSION
     @EXPORT_TRY @EXPORT_STACK @EXPORT_STRINGIFY @EXPORT_DEBUG @EXPORT_OK
     %EXPORT_TAGS
     $mod_perl $initialised $compiling
     $default
     $oldHandler
     @init_hooks);


use base qw(Exporter);
use POSIX qw(strftime);


@EXPORT_TRY=qw(try when except reraise finally);

@EXPORT_STACK=
  qw(FRAME_PACKAGE FRAME_FILE FRAME_LINE FRAME_SUBNAME
     FRAME_HASARGS FRAME_WANTARRAY FRAME_LAST);

@EXPORT_STRINGIFY=qw(STRINGIFY_STACK STRINGIFY_EXITCATCH);
@EXPORT_DEBUG=qw(DEBUG_NONE DEBUG_CONTEXT DEBUG_STACK DEBUG_ALL DEBUG_NOSTRIP);
@EXPORT_OK=(@EXPORT_TRY, @EXPORT_STACK, @EXPORT_STRINGIFY, @EXPORT_DEBUG);

%EXPORT_TAGS=
  (all       => \@EXPORT_OK,
   stack     => \@EXPORT_STACK,
   stringify => \@EXPORT_STRINGIFY,
   debug     => \@EXPORT_DEBUG,
   try       => \@EXPORT_TRY);


use constant DEBUG_NONE          => 0;
use constant DEBUG_CONTEXT       => 1;
use constant DEBUG_STACK         => 2;
use constant DEBUG_ALL           => 3;
use constant DEBUG_NOSTRIP       => 4;

use constant FRAME_PACKAGE       => 0;
use constant FRAME_FILE          => 1;
use constant FRAME_LINE          => 2;
use constant FRAME_SUBNAME       => 3;
use constant FRAME_HASARGS       => 4;
use constant FRAME_WANTARRAY     => 5;
use constant FRAME_LAST          => 5;

use constant STRINGIFY_STACK     => 0x100;
use constant STRINGIFY_EXITCATCH => 0x200;

use overload bool => sub {1};
use overload '""' => sub {local $@; shift->stringify};


sub _clone($);
sub _stringify($$);
sub _confess($$);


# needed if we're 'use'd (directly or indirectly) in perl-start
no warnings qw(redefine);


sub _resetDefault() {
  my $debuglevel=$ENV{_DEBUG_LEVEL} || 0;
  $debuglevel||=DEBUG_NOSTRIP if $compiling;
  $default=bless {}, 'Exception';
  $default->{TEXT}=[];
  $default->{ID}='';
  $default->{DEBUGLEVEL}=$debuglevel;
  $default->{STRINGIFY}=\&_stringify;
  $default->{CONFESS}=[\&_confess];
  $default->{CODE}=1;
  $default->{CHECKCGI}=$mod_perl ? 1 : 0;
  $initialised=0;
}


sub _initialise() {
  return if $initialised;
  _resetDefault;
  $initialised=1;

  Apache->request->register_cleanup(\&_resetDefault)
    if $mod_perl && exists $ENV{REQUEST_URI};

  my $handler=$SIG{__DIE__} || 'DEFAULT';

  unless ($handler eq \&_handler) {
    $oldHandler=$handler;
    $SIG{__DIE__}=\&_handler;
  }

  $_->() foreach @init_hooks;
}


sub _default() {
  _initialise unless $initialised;
  $default
}


sub _blessed($) {
  my $data=shift;
  my $ref=ref $data;
  local $SIG{__DIE__}='DEFAULT';
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


sub _cloneException($) {
  my $error=shift;
  my $ref=ref $error;

  my %error=map {
    $_ =>
      ($_ eq 'STRINGIFY' || $_ eq 'CONFESS') &&
      (!$error->{$_} || $error->{$_} eq $default->{$_})
	? undef : _clone $error->{$_}

  } keys %$error;

  my $foo=bless \%error, $ref;
  $foo
}


sub _isError($) {
  my $error=shift;
  local $SIG{__DIE__}='DEFAULT';
  ref $error && eval {$error->isa('Exception')}
}


sub _create($) {
  my $class=shift;
  return _cloneException $class if _isError $class;
  my $error=_cloneException _default;
  bless $error, ref $class || $class
}


sub _handler {
  my $error=shift;

  if (_isError $error) {
    $error->raise(@_);
  } else {
    my $text=join '', $error, @_;
    $text=~tr/\f\n\t\r / /s;
    $text=~s/^ ?(.*?) ?$/$1/;
    $text=~s/^\[.*?\] \w*: ?//;

    $text=~s/ ?at [\w\/\.\-]+ line \d+(\.$)?//
      unless _default->{DEBUGLEVEL}&DEBUG_NOSTRIP;

    _default->raise($text, {ID=>'die'});
  }
}


sub _stringifyStack($) {
  my $error=shift;
  my $stack=$error->{STACK};
  return () unless $stack;

  map {
    "$_->[FRAME_PACKAGE] \t$_->[FRAME_FILE] \t".
    "line $_->[FRAME_LINE] \t$_->[FRAME_SUBNAME]"
  } @$stack
}


sub _stringify($$) {
  my ($error, $option)=@_;
  return if $option&STRINGIFY_EXITCATCH;
  my $text=$error->{TEXT};
  my @stack=$option&STRINGIFY_STACK ? $error->_stringifyStack : ();
  join '', map {"$_\n"} @$text, (@stack ? ("\nStack trace:", @stack) : ())
}


sub _confess($$) {
  my ($error, $quiet)=@_;
  print STDERR $error->stringify(STRINGIFY_STACK) unless $quiet;
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
  my $error=_create $class;
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
  local $SIG{__DIE__}=$oldHandler;
  my $error=_create $class;
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

  my $debug=$error->{DEBUGLEVEL}&DEBUG_ALL;

  if ($debug) {
    my ($stack, @stack)=0;

    # the pending flag is a bit of magic for DEBUG_CONTEXT - we don't want
    # a stack entry added for reraise, but we *do* want one for die, so if
    # we have an internal raise, we check if the first external frame is for
    # a die (our $SIG{__DIE__} _handler)
    my $pending=0;

    while (my @frame=caller $stack++) {
      my $package=$frame[FRAME_PACKAGE];

      if ($mod_perl && $debug!=DEBUG_ALL) {
	next if $package=~m/^Apache::(Registry|PerlRun)$/;
	next if $package eq 'main' && $frame[FRAME_LINE]==0;
      }

      if ($package eq 'Exception') {
	$pending=1
	  if $debug==DEBUG_CONTEXT &&
	     $frame[FRAME_SUBNAME] eq 'Exception::raise';

	next if $debug!=DEBUG_ALL;
      } elsif ($mod_perl && $package=~m/^Apache::ROOT::(.*)$/) {
	$package=$1;
	# restore common filename chars
	$package=~s/_7e/~/g;
	$package=~s/_2e/./g;
	$package=~s/_2d/-/g;
	$frame[FRAME_PACKAGE]=$package;
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
    $error->{ID}=$template->{ID};
    $error->{DEBUGLEVEL}=$template->{DEBUGLEVEL};
    $error->{CONFESS}=$template->{CONFESS} ? [@{$template->{CONFESS}}] : undef;
    bless $error, ref $template;
  } else {
    $error->{ID}=$template;
  }

  $error
}


sub stringifier($;&) {
  my ($error, $code)=@_;

  if (_isError $error) {
    $code=$default->{STRINGIFY} if defined $code && !$code;
  } else {
    $error=_default;
    $code=\&_stringify if defined $code && !$code;
  }

  my $old=$error->{STRINGIFY};
  $error->{STRINGIFY}=$code if $code;
  $old
}


sub _matchstack($$$) {
  my ($frame, $package, $subname)=@_;
  my @frame=caller($frame+1)        or return 0;
  $frame[FRAME_PACKAGE] eq $package or return 0;
  $frame[FRAME_SUBNAME] eq "Exception::$subname" or return 0;
  1
}


# This is vile in order to deal with uncaught exceptions for any of
# straight CGI, Apache::PerlRun or Apache::Registry. The first of these
# is actually the hardest as there seems no way to easily catch that
# final die - we look at the stack to (hopefully) confirm the right
# circumstances. The other two cases are easier, as we only need to look
# at what fired up stringification; we print our error to STDERR and
# return undef (no error) to prevent the default mod_perl termination
# handling from being triggered. The 'return undef if ...' at the start
# is there because Apache::PerlRun stringifies twice.
#
# The assumption here is that the programmer has defined their own HTML
# stringifier and a confessor that outputs to STDOUT, it's up to them
# to write the page end tags if they get STRINGIFY_EXITCATCH.
#
# Needless to say, all this may stop working for future versions of
# mod_perl; the real answer is for scripts to always catch and deal with
# exceptions themselves properly, but that's asking too much :)
#
sub stringify($;$) {
  my ($error, $option)=@_;
  return undef if $error->{CHECKCGI}==2;
  my $stringify=$error->{STRINGIFY} || $default->{STRINGIFY};
  $option=0 unless defined $option;

  $option||=STRINGIFY_EXITCATCH
    if $error->{CHECKCGI} &&
       ($mod_perl
	  ? (caller 1)[FRAME_PACKAGE]=~m/^Apache::(Registry|PerlRun)$/
	  : (!caller 4) &&
	    (_matchstack 3, 'main', 'try') &&
	    (_matchstack 2, 'Exception', 'raise') &&
	    (_matchstack 1, 'Exception', '__ANON__'));

  my $text=$stringify->($error, $option);

  if ($option&STRINGIFY_EXITCATCH) {
    my @now=localtime;
    my @text=@{$error->{TEXT}};
    $text[0]="$0 : $text[0]";
    push @text, $error->_stringifyStack if $option&STRINGIFY_STACK;
    my $header=strftime "[%a %b %d %H:%M:%S %Y] [client] ", @now;
    my $errstr=join '', map {"$header$_\n"} @text;
    return $errstr unless $mod_perl;
    print STDERR $errstr;
    $error->{CHECKCGI}=2;
    return undef;
  }

  $text
}


sub stack($) {
  my $error=shift;
  $error->{STACK}
}


sub text($;$) {
  my ($error, $text)=@_;
  $error=_default unless _isError $error;
  my $old=$error->{TEXT};

  if (_isError $text) {
    push @{$error->{TEXT}}, @{$text->{TEXT}};
  } elsif (ref $text eq 'ARRAY') {
    $error->{TEXT}=$text;
  } elsif ($text) {
    push @{$error->{TEXT}}, $text;
  }

  $old
}


sub debugLevel($;$) {
  my ($error, $newLevel)=@_;
  $error=_default unless _isError $error;
  my $oldLevel=$error->{DEBUGLEVEL};
  $error->{DEBUGLEVEL}=$newLevel if defined $newLevel;
  $oldLevel
}


sub id($;$) {
  my ($error, $newId)=@_;
  $error=_default unless _isError $error;
  my $oldId=$error->{ID};
  $error->{ID}=$newId if defined $newId;
  $oldId
}


sub exitcode($;$) {
  my ($error, $newCode)=@_;
  $error=_default unless _isError $error;
  my $oldCode=$error->{CODE};
  $error->{CODE}=$newCode if defined $newCode;
  $oldCode
}


sub confessor($;&) {
  my ($error, $code)=@_;
  my $replace=ref $code eq 'ARRAY';

  if (_isError $error) {
    $code=$default->{CONFESS} if $replace && !@$code;
  } else {
    $error=_default;
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
  my $confess=$error->{CONFESS} || $default->{CONFESS};
  my $quiet=0;

  foreach (reverse @$confess) {
    next unless ref $_ eq 'CODE';
    $quiet=$_->($error, $quiet);
    $quiet=0 unless defined $quiet;
    last if $quiet<0;
  }
}


sub croak($;$) {
  my ($error, $exitcode)=@_;
  $exitcode=$error->{CODE} unless defined $exitcode;
  $error->confess;
  exit $exitcode;
}


sub registerDefault($) {
  my $class=shift;
  $class=ref $class if ref $class;
  _initialise unless $initialised;
  bless $default, $class;
}


sub initHook($&) {
  my ($class, $hook)=@_;

  foreach (@init_hooks) {
    return 0 if $_ eq $hook;
  }

  push @init_hooks, $hook;
  1
}


sub checkCGI($;$) {
  my ($error, $new)=@_;
  $error=_default unless _isError $error;
  my $old=$error->{CHECKCGI};

  $error->{CHECKCGI}=$new ? 1 : 0
    if defined $new && !$mod_perl;

  $old
}


sub _matches($@) {
  my $error=shift;

  foreach my $test (@_) {
    my $ref=ref $test;

    if ($ref eq 'Regexp') {
      m/$test/ and return 1 foreach @{$error->{TEXT}};
    } elsif (_isError $test) {
      ref $error eq $ref && $error->{ID} eq $test->{ID} and return 1;
    } else {
      $error->id eq $test and return 1;
    }
  }

  0
}


sub try(&;$) {
  my ($try, $actions)=@_;
  _initialise unless $initialised;
  my @caller=caller;
  my $ret=wantarray ? 2 : defined wantarray ? 1 : 0;
  my @retval;

  if ($ret>1) {
    @retval=eval {$try->()};
  } elsif ($ret) {
    $retval[0]=eval {$try->()};
  } else {
    eval {$try->()};
  }

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

	  if ($ret>1) {
	    @retval=eval {$@=$error; $code->($error, @retval)};
	  } elsif ($ret) {
	    $retval[0]=eval {$@=$error; $code->($error, $retval[1])};
	  } else {
	    eval {$@=$error; $code->($error)};
	  }

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

	if ($ret>1) {
	  @retval=eval {$@=$error; $_->($error, @retval)};
	} elsif ($ret) {
	  $retval[0]=eval {$@=$error; $_->($error, $retval[1])};
	} else {
	  eval {$@=$error; $_->($error)};
	}

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
      if ($ret>1) {
	@retval=eval {$_->($error, @retval)};
      } elsif ($ret) {
	$retval[0]=eval {$_->($error, $retval[1])};
      } else {
	eval {$_->($error)};
      }

      if ($@) {
	if ($propagate) {
	  # ick... we have an exception in a finally block after either a
	  # reraise or an exception in an except block (or, indeed, an
	  # exception in an earlier finally block); merging the exceptions
	  # is the least bad course of action
	  push @{$propagate->{TEXT}}, @{$@->{TEXT}};
	  $propagate->_stackmerge($@->{STACK});
	} else {
	  $propagate=$@;
	}
      }
    }
  }

  $propagate->raise if $propagate;
  $ret>1 ? @retval : $ret ? $retval[0] : undef
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


BEGIN {
  ($VERSION)=q$Revision: 1.7 $=~m/Revision:\s+([^\s]+)/;
  $mod_perl=$ENV{MOD_PERL};

  if ($mod_perl) {
    require Apache;
    import Apache qw(exit);
  }

  $compiling=1;
  _resetDefault;
}


INIT {$compiling=0}


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
    }
    when $err, except {
	my $error=shift;
	$error->confess;
      }
    when 'die', reraise
    except {
	shift->croak;
      }
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
is mapped onto the L<stringify|"stringify"> method so, by default, Perl
will simply print the error text on to I<STDERR> on termination.

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
B<Exception> module itself (and, if appropriate, within mod_perl).

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
  }
  when ['foo', qr/bar/, $err], except {
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
  }
  when 'die', reraise
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
  }
  when $myErr, reraise
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
  }
  except {
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
  }
  except {
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

=head2 stringify

  my $text=$err->stringify;
  my $text=$err->stringify(1);

Return the text and any saved stack trace of an exception object. the optional
parameter is a bitmask,

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

=head2 text

  my $text=$err->text;
  my $defaultText=Exception->text;
  my $old=$err->text($new);
  my $oldDefault=Exception->text($new);

Get or set the text of an exception. The routines all return a reference to
the array of error text strings held in the B<Exception> object before the
call. If I<text> is passed a text string, that text is added to the end of the
array; if I<text> is passed a reference to an array of strings, the array is
B<replaced> by the one given.

An exception also gains a line every time it is L<raise|"raise">d with a text parameter.
Actually, to be precise, L<raise|"raise"> creates a new exception object with the
extra line, but that's the sort of implementation detail you don't need to
know, unless of course you want to...

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

A useful example of a confessor would be code that printed an exception on
I<STDOUT> instead of I<STDERR> which, used in conjunction with a
L<stringifier|"stringifier"> that generated HTML, could be used within CGI
scripts.

A confessor routine is passed two parameters when called: the exception
object and a I<quiet> flag; if this is non-zero, the routine is expected not
to produce any output. The routine should return the new value of the flag:
C<0>, C<1> or C<-1>, the last telling B<Exception> to not call any further
display routines at all.

As a trivial example, here's the default routine provided:

  sub _confess($$) {
    my ($error, $quiet)=@_;
    print STDERR $error->stringify unless $quiet;
    $quiet
  }

=head2 stringifier

  my $code=$err->stringifier;
  my $defaultCode=Exception->stringifier;
  my $old=$err->stringifier($new);
  my $oldDefault=Exception->stringifier($new);

Get or set the code to stringify an exception object. This code will be called
by the stringification overloading and by the L<stringify|"stringify"> and
default L<confess|"confess"> methods (the latter is also called by the
<L<croak|"croak"> method).

Your stringifier routine takes two parameters: the exception object and the
option parameter passed to the L<stringify|"stringify"> method; import
I<:stringify> to get the symbolic bit names into your code:

=over 4

=item STRINGIFY_NOSTACK

return just the text even if a stack trace is available.

=item STRINGIFY_EXITCATCH

this bit shouldn't be set in user code; it will be set for you for mod_perl
scripts (and CGI scripts if you've set L<checkCGI|"checkCGI">) if your script
is exiting with an uncaught exception.

=back

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

Display the exception using the list of L<confessor|"confessor"> routines it
contains. By default, this will print the L<stringified|"stringify"> exception
on I<STDERR>.

=head2 croak

  $err->croak;
  $err->croak($exitCode);

Call the exception's L<confess|"confess"> method and terminate. If no exit code is
supplied, exit with the exception's exit code as set by the L<exitcode|"exitcode">
method.

=head2 registerDefault

  package MyError;
  @ISA=qw(Exception);
  use Exception qw(:all);
  BEGIN {MyError->registerDefault}

This package method reblesses the default and die exception objects as being
members of a subclass. This is intended for subclasses that reimplement the
L<stringify|"stringify"> method for a particular environment (typically a CGI
script) so that the default handling, in the absence of a caught try block, for
the inbuilt anonymous and die exception objects uses the subclassed
L<stringify|"stringify"> to render the exception.

Clearly, the last package that invokes this method gets the objects.

=head1 COMPATIBILTY

Code written prior to version 1.5 that calls the I<text> method will need
rewriting:

 1.4 and earlier                         1.5 and later

 scalar $err->text or $err->text(0)      => $err->stringify(1)
        $err->text(1)                    => join "\n", @{$err->text}
        $err->text(2)                    => $err->stringify or "$err"

 list   $err->text or $err->text(0 or 1) => @{$err->text}
        $err->text(2)                    => (@{$err->text}, $err->stack)

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
