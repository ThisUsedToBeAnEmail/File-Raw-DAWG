#!perl
use 5.008003;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'File::Raw::DAWG' ) || print "Bail out!\n";
}

diag( "Testing File::Raw::DAWG $File::Raw::DAWG::VERSION, Perl $], $^X" );
