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
# The refusals phase 01 tabled, now against the XS reader, and EACH ONE
# RUN IN A CHILD PROCESS so that a crash is reported as a crash. A
# segfault in the parent would take the harness with it and the run
# would look like a missing plan rather than what it is.
#
# Nine refusals, nine distinct messages. Phase 01 pinned eight and the
# ninth, a file shorter than a header, has no artifact to edit: it is
# made by truncating one.

my @CASE = (
    { name => 'a file shorter than a header',
      edit => sub { substr $_[0], 0, 40 },
      like => qr/shorter than a header/ },

    { name => 'bad magic',
      edit => sub { _splice($_[0], 0, "XRDAWG1\n") },
      like => qr/not a File::Raw::DAWG artifact/ },

    { name => 'CRLF line endings',
      edit => sub { _splice($_[0], 0, "FRDAWG1\r") },
      like => qr/line endings rewritten in transit/ },

    { name => 'a format version from the future',
      edit => sub { _splice($_[0], 8, pack 'V', 2) },
      like => qr/format version this reader does not know/ },

    { name => 'a flag this reader does not know',
      edit => sub { _splice($_[0], 24, pack 'V', 1) },
      like => qr/flag this reader does not know/ },

    { name => 'a half record on the end',
      edit => sub { $_[0] . "\0\0" },
      like => qr/not a whole number of records/ },

    { name => 'a node_count that disagrees',
      edit => sub { _splice($_[0], 12, pack 'V', 8) },
      like => qr/node_count disagrees with the length/ },

    { name => 'a record 0 that is not the sentinel',
      edit => sub { _splice($_[0], 64, pack 'V', 115) },
      like => qr/record 0 is not the sentinel/ },

    { name => 'a root past the end',
      edit => sub { _splice($_[0], 20, pack 'V', 9) },
      like => qr/root is not a record/ },
);

plan tests => 3 * @CASE + 1;

my $dir  = FRDTest::Tmp::dir();
my $good = FRDTest::Vector::artifact();
my $n    = 0;
my %seen;

for my $case (@CASE) {
    $n++;
    my $art = "$dir/bad-$n.dawg";
    FRDTest::Tmp::spew($art, $case->{edit}->($good));

    my ($status, $output) = _in_a_child($art);

    is($status & 127, 0, "$case->{name} does not crash the process")
        or diag("killed by signal " . ($status & 127));
    isnt($status, 0, "$case->{name} is refused");
    like($output, $case->{like}, "$case->{name} says why");
    $seen{$1} = 1 if $output =~ /open: \S+: (.+)/;
}

is(scalar keys %seen, scalar @CASE, 'nine refusals, nine distinct messages');

# Open the artifact in a child, so that a segfault is a signal we can
# report rather than the end of this test file.
sub _in_a_child {
    my ($path) = @_;
    my $out = `$^X -Iblib/lib -Iblib/arch -MFile::Raw::DAWG -e 'File::Raw::DAWG->open(\$ARGV[0])' $path 2>&1`;
    return ($?, $out);
}

sub _splice {
    my ($bytes, $at, $with) = @_;
    substr($bytes, $at, length $with) = $with;
    return $bytes;
}
