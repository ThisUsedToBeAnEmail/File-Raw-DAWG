#!perl
use 5.008003;
use strict;
use warnings;
use Test::More;
use FindBin ();
use lib "$FindBin::Bin/lib";
use FRDTest::Tmp ();
use File::Raw::DAWG;

# plan_file_raw_dawg/02-the-builder.md, "Determinism".
#
# The artifact is checked into a repository and its test rebuilds it and
# compares, so the same input must give the same bytes every time. Three
# things make it so and all three are asserted here: the input is sorted
# and checked rather than sorted; the freeze order is fixed by the
# algorithm; and nothing depends on hash iteration order, because the
# register is consulted and never walked.
#
# The last of those is the one a person would get wrong, and it is what
# the repeated builds in a single process are looking for: perl's hash
# seed is per process, so a register that leaked its iteration order
# into the output would still be stable within one run. The separate
# processes below are what make the assertion mean something.

plan tests => 9;

my $dir = FRDTest::Tmp::dir();

my @words = qw(
    ace aces act acts ape apes apt arc arcs are ares
    car card cards care cares cars cart carts cat cats
    do dog dogs doing done dot dots
    ice iced ices icy
);

my $list = "$dir/words.txt";
FRDTest::Tmp::list($list, @words);

# Twice in this process, to two different paths.
my $a = "$dir/a.dawg";
my $b = "$dir/b.dawg";
File::Raw::DAWG->build($list, $a);
File::Raw::DAWG->build($list, $b);
is(FRDTest::Tmp::slurp($a), FRDTest::Tmp::slurp($b),
    'the same list twice gives the same bytes');

# Twice more in fresh processes with a randomised hash seed, which is
# what a register that walked its own table would trip over.
my @fresh;
for my $i (1 .. 2) {
    my $out = "$dir/fresh-$i.dawg";
    my $rc  = system($^X, (map { "-I$_" } @INC[0 .. 2]),
                     '-MFile::Raw::DAWG',
                     '-e', 'File::Raw::DAWG->build($ARGV[0], $ARGV[1])',
                     $list, $out);
    is($rc, 0, "a fresh process built the list (run $i)") or next;
    push @fresh, FRDTest::Tmp::slurp($out);
}
SKIP: {
    skip 'a fresh process did not build', 1 unless @fresh == 2;
    is($fresh[0], $fresh[1], 'two fresh processes agree');
}
is($fresh[0], FRDTest::Tmp::slurp($a), 'and they agree with this process')
    if @fresh;

# The same content at a different path gives the same bytes: nothing of
# the path reaches the artifact.
my $elsewhere = "$dir/somewhere-else.txt";
FRDTest::Tmp::list($elsewhere, @words);
my $c = "$dir/c.dawg";
File::Raw::DAWG->build($elsewhere, $c);
is(FRDTest::Tmp::slurp($c), FRDTest::Tmp::slurp($a),
    'the path the list came from is not in the artifact');

# A list whose last line has no newline is the same automaton and a
# DIFFERENT digest, because the digest is over the file and the
# automaton is over the words. Both halves are asserted, because the
# whole point of the digest is that it tracks the file.
my $no_nl = "$dir/no-newline.txt";
FRDTest::Tmp::spew($no_nl, join("\n", @words));
my $d = "$dir/d.dawg";
my $built_d = File::Raw::DAWG->build($no_nl, $d);
my $built_a = File::Raw::DAWG->build($list, "$dir/a2.dawg");

is(substr(FRDTest::Tmp::slurp($d), 64), substr(FRDTest::Tmp::slurp($a), 64),
    'a missing final newline does not change the automaton');
isnt($built_d->{digest}, $built_a->{digest},
    'but it does change the digest, which is over the file');

# And the obvious one: the automaton accepts what it was given.
is($built_a->{words}, scalar @words, 'every word went in');
