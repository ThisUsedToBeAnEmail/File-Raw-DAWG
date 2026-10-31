#!perl
use 5.008003;
use strict;
use warnings;
use Test::More;
use FindBin ();
use lib "$FindBin::Bin/lib";
use FRDTest::Tmp ();
use File::Raw::DAWG;

# plan_file_raw_dawg/06-tests.md.
#
# A hundred thousand words, and the shape of them is the whole point.
#
# A hundred thousand RANDOM strings would be a corpus that tests one
# branch: they share almost no prefixes, so the register would barely
# ever find a match and minimisation would never be exercised. This list
# is built in three deliberate parts instead, and the test says which:
#
#   a third real English words, from t/data/english.txt;
#   a third those words with endings, so prefixes are shared deeply;
#   a third generated over a small alphabet, so the register sees states
#     nothing else produces and sees them thousands of times.
#
# Nothing large is checked in. The list is generated here from the small
# one, every time.

plan tests => 11;

my $dir  = FRDTest::Tmp::dir();
my $data = -f 't/data/english.txt' ? 't/data/english.txt' : '../t/data/english.txt';

ok(-f $data, 'the small English list is in the tree') or BAIL_OUT('no word list');

my @base = split /\n/, FRDTest::Tmp::slurp($data);
cmp_ok(scalar @base, '>', 1000, 'and it holds over a thousand words');

# Part two: real words with endings. Deep shared prefixes, which is what
# makes the register work for its living.
my @ENDING = qw(s ed ing er ers est ly ness ful less able ish);
my @derived = map { my $w = $_; map { "$w$_" } @ENDING } @base;

# Part three: generated. Every three letter prefix over a twelve letter
# alphabet, times a fixed set of endings: dense, deeply shared, and
# nothing like English.
my @A = ('a' .. 'l');
my @tail = (@A, map { my $x = $_; map { "$x$_" } @A } @A);
my @generated;
for my $x (@A) {
    for my $y (@A) {
        for my $z (@A) {
            push @generated, map { "$x$y$z$_" } @tail;
        }
    }
}

my %all = map { $_ => 1 } @base, @derived, @generated;
my @words = sort keys %all;

cmp_ok(scalar @words, '>', 90_000, 'the list is over ninety thousand words')
    or diag(scalar @words);

my $list = "$dir/large.txt";
my $art  = "$dir/large.dawg";
FRDTest::Tmp::list($list, @words);

my $started = time;
my $built = File::Raw::DAWG->build($list, $art);
my $took = time - $started;

is($built->{words}, scalar @words, 'the builder took every word');
diag(sprintf 'built %d words into %d records (%d bytes) in %ds',
     $built->{words}, $built->{nodes}, $built->{bytes}, $took);

# THE MINIMALITY ASSERTION, against a bound this test computes rather
# than against a number somebody once observed.
#
# An unminimised trie has exactly one node per letter that is not
# already on the path of the word before it, which is computable from a
# sorted list in one pass. A build that merges nothing lands on that
# number. A minimal one must be far below it for a corpus with this much
# shared structure, and if it ever is not, the register has stopped
# working and this is the test that says so.
my $trie = 1;
my $prev = '';
for my $w (@words) {
    my $common = 0;
    $common++ while $common < length($prev) && $common < length($w)
                 && substr($prev, $common, 1) eq substr($w, $common, 1);
    $trie += length($w) - $common;
    $prev = $w;
}
diag(sprintf 'an unminimised trie would be %d records; this is %d (%.1f%%)',
     $trie, $built->{nodes}, 100 * $built->{nodes} / $trie);

cmp_ok($built->{nodes}, '<', $trie * 0.5,
    'the automaton is under half the size of the trie it minimises');
cmp_ok($built->{nodes}, '>', 1000,
    'and it is not suspiciously small, which would mean words went missing');

my $d = File::Raw::DAWG->open($art);
is($d->word_count, scalar @words, 'the artifact says how many words it has');

# Every word, all ninety odd thousand of them.
my $missing = 0;
for my $w (@words) {
    $missing++ unless $d->contains($w);
    last if $missing > 5;
}
is($missing, 0, 'every word in the list is accepted');

# Near misses: the same words with a letter changed, dropped or added.
# They are only near misses if they are not in the list, and in a corpus
# this dense a great many mutations land back on a real word, so each
# one is checked against the list before it is used as evidence.
my $near_tested = 0;
my $near_wrong  = 0;
for my $i (0 .. $#words) {
    next if $i % 7;                 # a spread through the list, not a prefix of it
    my $w = $words[$i];
    my @try = (
        substr($w, 0, 1) . 'q' . substr($w, 2),     # a letter changed
        substr($w, 0, length($w) - 1),              # a letter dropped
        $w . 'qz',                                  # letters added
    );
    for my $near (@try) {
        next unless $near =~ /\A[a-z]{1,64}\z/;
        next if $all{$near};
        $near_tested++;
        $near_wrong++ if $d->contains($near);
    }
}
cmp_ok($near_tested, '>', 10_000, 'over ten thousand near misses were tried');
is($near_wrong, 0, 'and not one of them was accepted');

# Prefixes: every proper prefix of a spread of words must be a prefix.
my $prefix_wrong = 0;
for my $i (0 .. $#words) {
    next if $i % 101;
    my $w = $words[$i];
    for my $n (1 .. length($w) - 1) {
        $prefix_wrong++ unless $d->has_prefix(substr $w, 0, $n);
    }
}
is($prefix_wrong, 0, 'every proper prefix of a spread of words is a prefix');
