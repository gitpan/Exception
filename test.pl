# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

######################### We start with some black magic to print on failure.

# Change 1..1 below to 1..last_test_to_print .
# (It may become useful if the test is moved to ./t subdirectory.)

BEGIN { $| = 1; print "1..13\n"; }
END {print "not ok 1\n" unless $loaded;}
use Exception qw(:all);
$loaded = 1;
print "ok 1\n";
sub ok {my ($test, $ok)=@_; print 'not ' unless $ok; print "ok $test\n"}

######################### End of black magic.

my ($ok2, $ok3)=(0, 0);

try {
  die 'foo';
} except {
    $ok2=1;	# test die caught by default exception
  }
  finally {
    $ok3=1;	# test finally code run
  };

ok(2, $ok2);
ok(3, $ok3);

my ($ok4, $ok5)=(0, 1);

try {
  die 'bar';
} when 'die', except {
    $ok4=1;	# test die raises 'die' exception
  }
  except {
    $ok5=0;	# test default not called if exception matched
  };

ok(4, $ok4);
ok(5, $ok5);

my $err=new Exception 'baz';
my ($ok6, $ok7, $ok8, $ok9)=(0, 0, 1, 1);

try {
  $err->raise('baz');
} when $err, except {
    $ok6=1;	# test matching exception by type works
  }
  when qr/az/, except {
    $ok7=1;	# test matching by regexp works
  }
  when qr/zyzzy/, except {
    $ok8=0;	# test invalid regexp not matched
  }
  except {
    $ok9=0;	# test default not called if exception matched
  };

ok(6, $ok6);
ok(7, $ok7);
ok(8, $ok8);
ok(9, $ok9);

my ($ok10, $ok11, $ok12)=(1, 0, 1);

try {
  $err->as('plugh')->raise('a');
} when 'baz', except {
    $ok10=0;	# test change of id
  }
  when 'plugh', except {
    $ok11=1;	# test change of id
  }
  except {
    $ok12=0;	# test default not called if exception matched
  };

ok(10, $ok10);
ok(11, $ok11);
ok(12, $ok12);

my $ok13=0;

$err->confessor(sub{
  $ok13=1;	# test user-defined confess code called
  0
});

try {
  $err->raise('b');
} except {
    $err->confess;
  };

ok(13, $ok13);

exit;
