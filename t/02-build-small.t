#!perl
use 5.008003;
use strict;
use warnings;
use Test::More;
use FindBin ();
use lib "$FindBin::Bin/lib";
use FRDTest::Vector ();
use FRDTest::Reference ();
use FRDTest::Tmp ();
use File::Raw::DAWG;

# plan_file_raw_dawg/02-the-builder.md.
#
# The test that joins the two halves of the distribution: the six words
# of phase 01 must produce the hundred bytes phase 01 wrote out by hand.
#
# The vector is the expected value and the builder's output is the
# actual one, never the other way round. A round trip of build then read
# would let both halves be wrong the same way.

plan tests => 12;

my $dir  = FRDTest::Tmp::dir();
my $list = "$dir/six-words.txt";
my $art  = "$dir/six-words.dawg";

FRDTest::Tmp::spew($list, FRDTest::Vector::list_bytes());

my $built = File::Raw::DAWG->build($list, $art);

is($built->{words},  6,   'six words');
is($built->{nodes},  9,   'nine records, the sentinel included');
is($built->{bytes},  100, 'a hundred bytes');
is($built->{digest}, FRDTest::Vector::digest_hex(), 'the digest of the list');

my $got = FRDTest::Tmp::slurp($art);
is(length $got, 100, 'the file on disk is a hundred bytes');
is($got, FRDTest::Vector::artifact(), 'byte for byte the hand vector');

# If that comparison ever fails, this is the line that says where.
if ($got ne FRDTest::Vector::artifact()) {
    my $want = FRDTest::Vector::artifact();
    for my $i (0 .. length($want) - 1) {
        next if substr($got, $i, 1) eq substr($want, $i, 1);
        diag(sprintf 'byte %d: got %02x, want %02x',
             $i, ord substr($got, $i, 1), ord substr($want, $i, 1));
    }
}

# The freeze order phase 01 guessed at, settled. The plan said to record
# here whether the builder's natural order really is the tabled one; it
# is, and these two assertions are what say so.
my $d = FRDTest::Reference->new($got);
is($d->root, 7, 'the start state is frozen last, at record 7');
is_deeply($d->trace('cars')->[-1], $d->trace('cats')->[-1],
    'cars and cats share the record the plan said they would');

# The empty automaton: the sentinel alone, and a root of 0.
my $empty_list = "$dir/empty.txt";
my $empty_art  = "$dir/empty.dawg";
FRDTest::Tmp::spew($empty_list, '');
my $none = File::Raw::DAWG->build($empty_list, $empty_art);
is($none->{words}, 0, 'no words');
is($none->{nodes}, 1, 'the sentinel alone');
is($none->{bytes}, 68, 'the header plus one record');

my $empty = eval { FRDTest::Reference->new(FRDTest::Tmp::slurp($empty_art)) };
is($@, '', 'and it is a valid artifact') or diag($@);
