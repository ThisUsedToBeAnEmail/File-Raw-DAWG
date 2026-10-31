#!perl
use 5.008003;
use strict;
use warnings;
use Test::More;
use FindBin ();
use lib "$FindBin::Bin/lib";
use FRDTest::Tmp ();
use File::Raw::DAWG;

# plan_file_raw_dawg/03-the-query.md, "Mapping, and the fallback".
#
# A fallback that reports PASS is a failing test, so `mapped` is
# ASSERTED rather than accepted either way: on this platform the default
# must really map, and `mmap => 0` must really not.
#
# The second half is the one that matters and it is the reason the
# `_buf` comment in DAWG.pm is shouted. File::Raw's data() hands back a
# scalar whose PV points straight at the mapping. Reading through it
# costs nothing. BINDING IT COPIES THE WHOLE MAPPING, and a reader that
# did that would have all of mmap's complexity and none of its point.

plan tests => 8;

my $dir  = FRDTest::Tmp::dir();
my $list = "$dir/words.txt";
my $art  = "$dir/words.dawg";

my @words = _some_words();
FRDTest::Tmp::list($list, @words);
File::Raw::DAWG->build($list, $art);

my $mapped  = File::Raw::DAWG->open($art);
my $slurped = File::Raw::DAWG->open($art, { mmap => 0 });

is($mapped->mapped,  1, 'the default really maps on this platform');
is($slurped->mapped, 0, 'and mmap => 0 really does not');

is($mapped->node_count, $slurped->node_count, 'both read the same node count');
is($mapped->word_count, $slurped->word_count, 'both read the same word count');
is($mapped->list_digest, $slurped->list_digest, 'both read the same digest');

my $disagreements = 0;
my $accepted = 0;
for my $w (@words, map { $_ . 'x' } @words) {
    my $a = $mapped->contains($w);
    my $b = $slurped->contains($w);
    $disagreements++ if $a != $b;
    $accepted += $a;
}
is($disagreements, 0, 'the two readers agree over ' . (2 * @words) . ' words');
is($accepted, scalar @words, 'and between them they accept exactly the list');

# The whole reason for the rule in _buf: a large artifact read through
# the mapping must not grow the process by its own size.
SKIP: {
    skip 'no ps on this platform', 1 unless -x '/bin/ps';

    my $big_list = "$dir/big.txt";
    my $big_art  = "$dir/big.dawg";
    FRDTest::Tmp::list($big_list, _many_words());
    my $built = File::Raw::DAWG->build($big_list, $big_art);

    my $before = _rss();
    my $big = File::Raw::DAWG->open($big_art);
    my $hits = 0;
    $hits += $big->contains($_) for _many_words();
    my $after = _rss();

    my $grew = $after - $before;
    my $size = int($built->{bytes} / 1024);
    cmp_ok($grew, '<', $size + 512,
        "reading a ${size}K artifact through the mapping grew the process by "
      . "${grew}K, which is under the artifact's own size plus slack");
}

sub _rss {
    my $out = `/bin/ps -o rss= -p $$`;
    $out =~ s/\s//g;
    return $out + 0;
}

sub _some_words {
    return sort qw(
        ace aces act acts ape apes apt arc arcs are ares
        car card cards care cares cars cart carts cat cats
        do dog dogs doing done dot dots
        ice iced ices icy
    );
}

# Enough words that a copy would show: every three letter combination of
# a small alphabet, four letters deep.
sub _many_words {
    my @out;
    my @a = ('a' .. 'l');
    for my $x (@a) {
        for my $y (@a) {
            for my $z (@a) {
                push @out, "$x$y$z";
                push @out, "$x$y$z$_" for @a;
            }
        }
    }
    return sort @out;
}
