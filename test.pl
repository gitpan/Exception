# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

######################### We start with some black magic to print on failure.

# Change 1..1 below to 1..last_test_to_print .
# (It may become useful if the test is moved to ./t subdirectory.)

BEGIN { $| = 1; print "1..4\n"; }
END {print "not ok 1\n" unless $loaded;}
use Exception qw(try catch throw rethrow);
$loaded = 1;
print "ok 1 [compile]\n";

######################### End of black magic.

# Insert your test code below (better if it prints "ok 13"
# (correspondingly "not ok 13") depending on the success of chunk 13
# of the test code):

# this basicly creates a new exception type...
use strict;
use vars qw($e);
@Test::Exception::ISA = qw(Exception);

try {
  throw(new Test::Exception(q(This is supposed to happen (I know it's ugly).)));
};
if(catch(qw(Test::Exception e))) {
  #print $e->as_string(),"\n";
  print "ok 2 [catch typed exception]\n";
}
elsif(catch(qw(Exception e))) {
  print "not ok 2 [catch typed exception]\n";
}
else {
  print "not ok 2 [catch typed excption]\n";
}

try {
  throw(new Test::Exception(q(This is supposed to happen (I know it's ugly).)));
};
if(catch(qw(Exception e))) {
  print "ok 3 [catch exception by base type]\n";
}
else {
  print "not ok 3 [catch excption by base type]\n";
}

try {
  throw(q(This is an old style exception.));
};
if(catch(qw(Exception e))) {
  print "not ok 4 [catch un-typed exception]\n";
}
else {
  print "ok 4 [catch un-typed excption]\n";
}

