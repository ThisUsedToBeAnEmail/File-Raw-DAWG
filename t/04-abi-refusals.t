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
# The same nine refusals t/03-open-refusals.t puts to the Perl reader,
# put to a C consumer instead. A consumer that cannot tell a truncated
# artifact from a rewritten header cannot report a bad deploy, so the
# codes are part of the ABI and are pinned here by number.
#
# The numbers are HAND: they come from include/file_raw_dawg.h, and the
# point of restating them is that changing one is a change to the ABI
# and has to be a deliberate edit to this list.

my $dir = FRDTest::Tmp::dir();
my ($exe, $log) = FRDTest::CC::build($dir);

if (!$exe) {
    plan skip_all => 'cannot compile a C consumer here: ' . $log;
}

my @CASE = (
    { name => 'shorter than a header',
      code => -1,
      edit => sub { substr $_[0], 0, 40 } },

    { name => 'CRLF line endings',
      code => -2,
      edit => sub { _splice($_[0], 0, "FRDAWG1\r") } },

    { name => 'not this format at all',
      code => -3,
      edit => sub { _splice($_[0], 0, "XRDAWG1\n") } },

    { name => 'a format version from the future',
      code => -4,
      edit => sub { _splice($_[0], 8, pack 'V', 2) } },

    { name => 'a flag this reader does not know',
      code => -5,
      edit => sub { _splice($_[0], 24, pack 'V', 1) } },

    { name => 'not a whole number of records',
      code => -6,
      edit => sub { $_[0] . "\0\0" } },

    { name => 'a node_count that disagrees',
      code => -7,
      edit => sub { _splice($_[0], 12, pack 'V', 8) } },

    { name => 'a record 0 that is not the sentinel',
      code => -8,
      edit => sub { _splice($_[0], 64, pack 'V', 115) } },

    { name => 'a root past the end',
      code => -9,
      edit => sub { _splice($_[0], 20, pack 'V', 9) } },
);

plan tests => 2 * @CASE + 2;

my $good = FRDTest::Vector::artifact();
my $n    = 0;
my %code;

for my $case (@CASE) {
    $n++;
    my $art = "$dir/bad-$n.dawg";
    FRDTest::Tmp::spew($art, $case->{edit}->($good));

    my $out = FRDTest::CC::run($exe, $art);
    my ($got, $why) = $out =~ /^refused (-?\d+) (.+)$/m;

    is($got, $case->{code}, "$case->{name} is FRD_E code $case->{code}")
        or diag($out);

    # The same artifact, the same complaint, through the Perl reader.
    # A C consumer and an XS reader disagreeing about what is wrong with
    # a file would be worse than either of them being wrong alone.
    eval { File::Raw::DAWG->open($art) };
    my $perl = $@;
    like($perl, qr/\Q$why\E/, "$case->{name}: the XS reader says the same thing")
        or diag("C said: $why\nPerl said: $perl");

    $code{$got} = 1;
}

is(scalar keys %code, scalar @CASE, 'nine refusals, nine distinct codes');

# A good artifact is not refused, which is what stops all of the above
# passing for the wrong reason.
{
    my $art = "$dir/good.dawg";
    FRDTest::Tmp::spew($art, $good);
    my $out = FRDTest::CC::run($exe, $art);
    like($out, qr/\Aopened /, 'and a good artifact is still opened');
}

sub _splice {
    my ($bytes, $at, $with) = @_;
    substr($bytes, $at, length $with) = $with;
    return $bytes;
}
