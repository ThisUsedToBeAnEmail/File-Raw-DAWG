#!perl
use 5.008003;
use strict;
use warnings;
use Test::More;
use FindBin ();
use lib "$FindBin::Bin/lib";
use FRDTest::Vector ();
use FRDTest::Tmp ();
use FRDTest::CC ();
use File::Raw::DAWG;

# plan_file_raw_dawg/04-the-abi.md.
#
# A C program, compiled against the installed header and NOTHING ELSE,
# walking the same six word artifact and reaching the same answers as
# the Perl reader and as the table phase 01 worked out by hand.
#
# The command line is the assertion. One -I, to where make installed the
# header, and no perl headers at all: if this compiles, the header is
# Perl-free in the way the plan promised, and if it agrees, the layout
# in it is the layout the XS is using.

my $dir = FRDTest::Tmp::dir();
my ($exe, $log) = FRDTest::CC::build($dir);

if (!$exe) {
    plan skip_all => 'cannot compile a C consumer here: ' . $log;
}

plan tests => 13;

diag('compiled with: ' . (split /\n/, $log)[0]);

my $art = "$dir/six.dawg";
FRDTest::Tmp::spew($art, FRDTest::Vector::artifact());

my $out = FRDTest::CC::run($exe, $art, qw(cat ca cars cats dot));
my %said = map { /\A(\w+) (\S+)(?: (.*))?\z/ ? ("$1 $2" => defined $3 ? $3 : '') : () }
           split /\n/, $out;

like($out, qr/\Aopened /, 'the C program opened the artifact')
    or diag($out);

# The header, as the hand vector wrote it.
is($said{'opened nodes'}, '9 words 6 root 7', 'nodes 9, words 6, root 7');

# The four walks of plan_file_raw_dawg/01-the-format.md, in C.
is($said{'contains cat'},  1, 'cat is accepted');
is($said{'trace cat'},     '7 4 3', 'cat walks 7, 4, 3');
is($said{'contains ca'},   0, 'ca is not a word');
is($said{'prefix ca'},     1, 'but it is a prefix');
is($said{'contains cars'}, 1, 'cars is accepted');
is($said{'trace cars'},    '7 4 2 1', 'cars walks 7, 4, 2, 1');
is($said{'trace cats'},    '7 4 3 1', 'cats walks 7, 4, 3, 1');
is($said{'contains dot'},  0, 'dot is refused');

# And the C agrees with the Perl, which is the check that catches a
# header that drifts away from the XS rather than away from the table.
my $d = File::Raw::DAWG->open($art);
my $disagreements = 0;
for my $w (qw(cat ca cars cats dot car do dog zebra cart)) {
    my $c = FRDTest::CC::run($exe, $art, $w);
    my ($contains) = $c =~ /^contains \Q$w\E (\d)$/m;
    my ($prefix)   = $c =~ /^prefix \Q$w\E (\d)$/m;
    $disagreements++ if $contains != $d->contains($w);
    $disagreements++ if $prefix   != $d->has_prefix($w);
}
is($disagreements, 0, 'the C consumer and the XS reader agree on ten words');

# The header alone, with warnings as errors, is the other half of the
# promise: a consumer should not have to silence anything to include it.
unlike($log, qr/warning/i, 'and it compiled without a warning');
like($log, qr/-Wall/, 'with warnings actually turned on');
