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
# Open a reader and drop it, ten thousand times, and watch what the
# process does.
#
# This distribution has no DESTROY of its own: the reader holds a
# File::Raw::mmap object, and that unmaps when it is collected
# (File::Raw::mmap::DESTROY exists; File-Raw/file.c:3790). That is a
# claim about somebody else's code made in plan_file_raw_dawg/03, and a
# claim like that should be measured rather than believed. If it were
# wrong, ten thousand mappings would accumulate and this is where it
# would show.
#
# The builder gets the same treatment, because it is the other thing
# that allocates: it holds an arena and a register, and File::Raw::DAWG
# frees the handle on every path out of build, including the ones that
# die.

my $dir  = FRDTest::Tmp::dir();
my $list = "$dir/words.txt";
my $art  = "$dir/words.dawg";

# Big enough that a leaked mapping is visible and a leaked arena is
# obvious, small enough that ten thousand rounds is quick.
my @words = sort map { my $a = $_; map { "$a$_" } ('aa' .. 'zz') } ('a' .. 'z');
FRDTest::Tmp::list($list, @words);
File::Raw::DAWG->build($list, $art);

my $size = -s $art;

if (!-x '/bin/ps') {
    plan skip_all => 'no ps on this platform to watch the process with';
}

plan tests => 6;

diag(sprintf 'the artifact is %d bytes, %d words', $size, scalar @words);

# Warm up first. The first few hundred rounds grow the process for
# reasons that have nothing to do with us: the arena perl allocates for
# its own bookkeeping settles, and measuring through that would make a
# leak test that reports whatever the interpreter felt like.
_open_and_drop($art, 500);
my $before = _rss();

_open_and_drop($art, 10_000);
my $after = _rss();
my $grew = $after - $before;

diag(sprintf 'ten thousand open-and-drop rounds grew the process by %d KB', $grew);

# A leaked mapping is $size per round. Ten thousand of them would be
# hundreds of megabytes; the mark is generous because the point is to
# catch that, not to police perl's allocator.
cmp_ok($grew, '<', 4096,
    'ten thousand readers opened and dropped grew the process by under 4 MB');
cmp_ok($grew * 1024, '<', $size * 100,
    'which is under a hundred artifacts, not ten thousand');

# The slurping reader, for the same reason: it holds a scalar of the
# whole artifact and that scalar must go when the reader does.
my $before_slurp = _rss();
_open_and_drop($art, 10_000, { mmap => 0 });
my $grew_slurp = _rss() - $before_slurp;
diag(sprintf 'the same with mmap => 0 grew it by %d KB', $grew_slurp);
cmp_ok($grew_slurp, '<', 4096, 'and the slurping reader does not leak either');

# The builder: ten thousand builds of a small list, each of which
# allocates an arena and a register and must give both back.
my $small = "$dir/small.txt";
FRDTest::Tmp::list($small, qw(car cars cat cats do dog));
my $out = "$dir/small.dawg";
File::Raw::DAWG->build($small, $out);
my $before_build = _rss();
File::Raw::DAWG->build($small, $out) for 1 .. 2_000;
my $grew_build = _rss() - $before_build;
diag(sprintf 'two thousand builds grew the process by %d KB', $grew_build);
cmp_ok($grew_build, '<', 4096, 'two thousand builds do not leak');

# And the path that dies: build refuses the list, and the handle it was
# holding has to be freed on the way out. A leak here would be the one
# nobody notices, because it only happens when something else is already
# going wrong.
my $bad = "$dir/bad.txt";
FRDTest::Tmp::list($bad, qw(cat car));         # out of order
my $before_die = _rss();
for (1 .. 2_000) {
    eval { File::Raw::DAWG->build($bad, "$dir/never.dawg") };
}
my $grew_die = _rss() - $before_die;
diag(sprintf 'two thousand failed builds grew the process by %d KB', $grew_die);
cmp_ok($grew_die, '<', 4096, 'two thousand failed builds do not leak either');

ok(!-e "$dir/never.dawg", 'and not one of them left an artifact behind');

sub _open_and_drop {
    my ($path, $times, $opts) = @_;
    for (1 .. $times) {
        my $d = File::Raw::DAWG->open($path, $opts);
        # Touch it, so that a lazy mapping is really made.
        $d->contains('abc');
    }
    return;
}

sub _rss {
    my $out = `/bin/ps -o rss= -p $$`;
    $out =~ s/\s//g;
    return $out + 0;
}
