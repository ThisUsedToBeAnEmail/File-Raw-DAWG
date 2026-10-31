#!perl
use 5.008003;
use strict;
use warnings;
use Test::More;
use FindBin ();
use lib "$FindBin::Bin/lib";
use FRDTest::Vector ();
use FRDTest::Tmp ();
use File::Raw::DAWG;

# plan_file_raw_dawg/03-the-query.md.
#
# The XS reader over the six word artifact, measured against the walks
# phase 01 worked out by hand and against the pure Perl reference reader
# that phase 01 wrote from the bit layout. Two independent readers
# agreeing with a hand table is the point: a round trip through one
# reader would prove only that it disagrees with nothing.

plan tests => 6;

my $dir = FRDTest::Tmp::dir();
my $art = "$dir/six.dawg";
FRDTest::Tmp::spew($art, FRDTest::Vector::artifact());

my $d = File::Raw::DAWG->open($art);

subtest 'the header, as the hand vector wrote it' => sub {
    plan tests => 5;
    is($d->node_count, 9, 'nine records');
    is($d->word_count, 6, 'six words');
    is($d->root, 7, 'the start state begins at record 7');
    is($d->list_digest, FRDTest::Vector::digest_hex(), 'the source list digest');
    is($d->path, $art, 'and it remembers what it opened');
};

subtest 'the four walks the plan worked by hand' => sub {
    plan tests => 9;

    # cat: 7 is c, 4 is a, the group at 2 holds r and is not last, so
    # the scan steps to 3, which is t and terminal.
    ok($d->contains('cat'), 'cat is accepted');
    is_deeply(_trace($d, 'cat'), [ 7, 4, 3 ], 'cat walks 7, 4, 3');

    # ca: ends at record 4, terminal clear, child 2.
    ok(!$d->contains('ca'), 'ca is not a word');
    ok($d->has_prefix('ca'), 'ca is a prefix');

    # cars and cats both reach record 1. The share made visible.
    ok($d->contains('cars') && $d->contains('cats'), 'cars and cats are accepted');
    is_deeply(_trace($d, 'cars'), [ 7, 4, 2, 1 ], 'cars walks 7, 4, 2, 1');
    is_deeply(_trace($d, 'cats'), [ 7, 4, 3, 1 ], 'cats walks 7, 4, 3, 1');
    is(_trace($d, 'cars')->[-1], _trace($d, 'cats')->[-1],
        'and they end on the same record');

    # dot: the group at 5 holds g alone and is last.
    ok(!$d->contains('dot'), 'dot is refused');
};

subtest 'every word, every prefix, and twenty refusals' => sub {
    my @words = FRDTest::Vector::words();
    my %prefix;
    for my $w (@words) {
        $prefix{substr $w, 0, $_} = 1 for 1 .. length($w) - 1;
    }
    my @refuse = qw(ca c d dot cart care dogs cas rat at ct DOG zebra carsx catsy);
    plan tests => @words + keys(%prefix) + @refuse + 4;

    ok($d->contains($_), "$_ is accepted") for @words;
    ok($d->has_prefix($_), "$_ is a prefix") for sort keys %prefix;
    ok(!$d->contains($_), "$_ is refused") for @refuse;

    # A question with a plain answer, never a croak.
    is($d->contains(''), 0, 'the empty word is refused');
    is($d->has_prefix(''), 1, 'the empty prefix is a prefix');
    is($d->contains('do g'), 0, 'a space is not a letter');
    is($d->contains(undef), 0, 'undef is refused rather than warned about');
};

subtest 'the walk, handle by handle' => sub {
    plan tests => 11;

    my $start = $d->root;
    my $c = $d->child($start, 'c');
    is($c, 7, 'child(root, c) is the transition at 7');
    is($d->is_terminal($c), 0, 'c does not end a word');

    my $after_c = $d->next_node($c);
    is($after_c, 4, 'and it arrives at the state at 4');

    my $a = $d->child($after_c, 'a');
    is($a, 4, 'child(that, a) is the transition at 4');

    my $after_ca = $d->next_node($a);
    is($after_ca, 2, 'which arrives at the state at 2');

    is_deeply($d->children($after_ca),
        [ [ 'r', 2, 1 ], [ 't', 3, 1 ] ],
        'whose transitions are r and t, both ending a word');

    is($d->child($after_ca, 'z'), undef, 'a letter the state has not got is undef');
    is($d->child($after_ca, 'zz'), undef, 'and so is a non-letter');

    # s arrives at the empty state, which has no group at all.
    my $s = $d->child($d->next_node($d->child($after_ca, 'r')), 's');
    is($s, 1, 'the s of cars is the transition at 1');
    is($d->is_terminal($s), 1, 'which ends a word');
    is($d->next_node($s), undef, 'and arrives nowhere: the empty state');
};

subtest 'step does a whole edge in one call' => sub {
    plan tests => 6;

    my ($next, $terminal) = $d->step($d->root, 'c');
    is($next, 4, 'step(root, c) arrives at 4');
    is($terminal, 0, 'and c does not end a word');

    ($next, $terminal) = $d->step(4, 'a');
    is($next, 2, 'step(4, a) arrives at 2');
    is($terminal, 0, 'and ca does not end a word');

    ($next, $terminal) = $d->step(2, 'r');
    is($terminal, 1, 'step(2, r) ends a word, which is car');

    my @none = $d->step(2, 'z');
    is(scalar @none, 0, 'a letter the state has not got is the empty list');
};

subtest 'the empty automaton answers everything with no' => sub {
    plan tests => 5;
    my $list = "$dir/empty.txt";
    my $none = "$dir/empty.dawg";
    FRDTest::Tmp::spew($list, '');
    File::Raw::DAWG->build($list, $none);

    my $e = File::Raw::DAWG->open($none);
    is($e->node_count, 1, 'the sentinel alone');
    is($e->word_count, 0, 'no words');
    is($e->root, 0, 'and no root');
    is($e->contains('cat'), 0, 'nothing is in it');
    is($e->has_prefix(''), 1, 'but the empty prefix still is');
};

# The record indices a word visits, using only the public walk.
sub _trace {
    my ($dawg, $word) = @_;
    my @path;
    my $state = $dawg->root;
    for my $letter (split //, $word) {
        my $at = $dawg->child($state, $letter);
        return undef unless defined $at;
        push @path, $at;
        $state = $dawg->next_node($at);
        last unless defined $state;
    }
    return \@path;
}
