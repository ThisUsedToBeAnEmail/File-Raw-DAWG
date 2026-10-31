#!perl
use 5.008003;
use strict;
use warnings;
use Test::More;
use FindBin ();
use lib "$FindBin::Bin/lib";
use FRDTest::Tmp ();
use FRDTest::Reference ();
use File::Raw::DAWG;

# plan_file_raw_dawg/02-the-builder.md.
#
# THE FILE THAT CATCHES A BUILD THAT IS MERELY CORRECT.
#
# A DAWG that fails to merge anything still accepts exactly the right
# words and is simply larger, so it passes every other test in this
# distribution. These four lists are small enough that a person can
# count the records of the minimal automaton, and the count is written
# out with its reasoning beside it. Break the register and only this
# file goes red.
#
# "Records" throughout includes record 0, the sentinel.

my @CASE = (
    {
        name  => 'one word, nothing to share',
        words => [qw(cat)],
        nodes => 4,
        why   => 'one record a letter, c a t, plus the sentinel. 3 + 1',
        root  => 3,
    },
    {
        name  => 'a word and its extension',
        words => [qw(cat cats)],
        nodes => 5,
        why   => 'c a t s in a line, each its own record, plus the sentinel. '
               . 'Nothing merges: every state has one way out and they all '
               . 'differ. 4 + 1',
        root  => 4,
    },
    {
        name  => 'a shared suffix under different first letters',
        words => [qw(ace ice)],
        nodes => 5,
        why   => 'the state after "a" and the state after "i" are both '
               . '"c then e, and e ends a word", so they are one run: '
               . 'e, then c, then the start state a and i. 4 + 1. '
               . 'Unminimised it would be a c e i c e, which is 7',
        root  => 3,
    },
    {
        name  => 'the four word merge of phase 01',
        words => [qw(car cars cat cats)],
        nodes => 6,
        why   => 'after "car" and after "cat" the only way on is s, and s '
               . 'ends a word in both, so the two states are one record. '
               . 's, then r and t together, then a, then c. 5 + 1. '
               . 'Unminimised it would be c a r s t s, which is 7',
        root  => 5,
    },
);

plan tests => 4 * @CASE;

my $dir = FRDTest::Tmp::dir();
my $n   = 0;

for my $case (@CASE) {
    $n++;
    my $list = "$dir/min-$n.txt";
    my $art  = "$dir/min-$n.dawg";
    FRDTest::Tmp::list($list, @{ $case->{words} });

    my $built = File::Raw::DAWG->build($list, $art);

    is($built->{words}, scalar @{ $case->{words} },
        "$case->{name}: " . scalar(@{ $case->{words} }) . ' words');
    is($built->{nodes}, $case->{nodes},
        "$case->{name}: $case->{nodes} records ($case->{why})");

    my $d = FRDTest::Reference->new(FRDTest::Tmp::slurp($art));
    is($d->root, $case->{root}, "$case->{name}: the root is record $case->{root}");

    my $all = 1;
    for my $w (@{ $case->{words} }) {
        $all = 0 unless $d->contains($w);
    }
    ok($all, "$case->{name}: and it still accepts every word");
}
