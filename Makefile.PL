#!/usr/bin/perl
use ExtUtils::MakeMaker;
use strict;

WriteMakefile (
    NAME            => 'Exception',
    VERSION_FROM    => 'lib/Exception.pm', # finds $VERSION
    dist            => { COMPRESS => 'gzip -9f', SUFFIX => 'gz' },
    PMLIBDIRS       => [ 'lib' ],
    PREREQ_PM       => {
        'Test::Unit'    => 0, 
    },
    AUTHOR          => 'Piotr Roszatycki <dexter@debian.org>',
    ABSTRACT        => 'Error handling with exception class'
);
