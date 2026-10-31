#!perl
use 5.008003;
use strict;
use warnings;
use Test::More;
use FindBin ();
use lib "$FindBin::Bin/lib";
use FRDTest::Tmp ();
use File::Raw::DAWG;

# plan_file_raw_dawg/02-the-builder.md, "What a bad input is".
#
# Dying is the whole error strategy. There is no "skipped 41 lines"
# summary, because a consumer that silently loses words ships a lexicon
# that refuses a word for no reason a player can see.
#
# Each case is its own file and its own message, and each asserts that
# NO ARTIFACT WAS WRITTEN: a build that dies half way must not leave
# something behind that looks finished.

my @CASE = (
    {
        name  => 'out of order',
        bytes => "cat\ncar\n",
        like  => qr/line 2 \('car'\).*out of order.*word before was 'cat'/,
    },
    {
        name  => 'a repeat',
        bytes => "cat\ncat\n",
        like  => qr/line 2 \('cat'\).*repeat of the word before/,
    },
    {
        name  => 'an empty line',
        bytes => "cat\n\ndog\n",
        like  => qr/line 2 is not a word of a to z: ''/,
    },
    {
        name  => 'a capital',
        bytes => "Cat\n",
        like  => qr/line 1 is not a word of a to z: 'Cat'/,
    },
    {
        name  => 'a hyphen',
        bytes => "co-op\n",
        like  => qr/line 1 is not a word of a to z: 'co-op'/,
    },
    {
        name  => 'an apostrophe',
        bytes => "cat\ndog's\n",
        like  => qr/line 2 is not a word of a to z/,
    },
    {
        name  => 'trailing whitespace',
        bytes => "cat \n",
        like  => qr/line 1 is not a word of a to z: 'cat '/,
    },
    {
        name  => 'a word past the cap',
        bytes => ('a' x 65) . "\n",
        like  => qr/line 1.*longer than the word cap/,
    },
    {
        name  => 'a byte outside ASCII',
        bytes => "caf\xc3\xa9\n",
        like  => qr/line 1 is not a word of a to z.*\\xc3/,
    },
    {
        name  => 'CRLF line endings',
        bytes => "cat\r\ndog\r\n",
        like  => qr/line 1 has a carriage return.*CRLF/,
    },
);

plan tests => 3 * @CASE + 2;

my $dir = FRDTest::Tmp::dir();
my $n   = 0;

for my $case (@CASE) {
    $n++;
    my $list = "$dir/bad-$n.txt";
    my $art  = "$dir/bad-$n.dawg";
    FRDTest::Tmp::spew($list, $case->{bytes});

    my $built = eval { File::Raw::DAWG->build($list, $art) };
    my $why   = $@;

    ok(!$built, "$case->{name} is refused");
    like($why, $case->{like}, "$case->{name} says which line and why");
    ok(!-e $art, "$case->{name} leaves no artifact");
}

# A word of exactly the cap is fine: the refusal is past it, not at it.
{
    my $list = "$dir/at-the-cap.txt";
    my $art  = "$dir/at-the-cap.dawg";
    FRDTest::Tmp::spew($list, ('a' x 64) . "\n");
    my $built = eval { File::Raw::DAWG->build($list, $art) };
    ok($built, 'a word of exactly the cap is accepted') or diag($@);
    is($built ? $built->{words} : -1, 1, 'and it is the one word');
}
