package FRDTest::Vector;

use 5.008003;
use strict;
use warnings;

our $VERSION = '0.01';

# THE FIXED POINT OF THIS DISTRIBUTION.
#
# The six word automaton of plan_file_raw_dawg/01-the-format.md, written
# out by hand there and again here, and the hundred bytes it must be.
#
# Nothing in this file is produced by the code under test. The builder is
# measured against these bytes and the reader is measured against these
# walks; a round trip of build-then-read would let both halves be wrong
# the same way, which is the whole reason this module exists.
#
# The format's numbers are NOT restated here. They are parsed out of
# include/file_raw_dawg.h, which is the normative copy, so a header that
# drifts fails the tests rather than quietly disagreeing with them.

my $HEADER = 'include/file_raw_dawg.h';

# The list, sorted, as the builder must receive it.
my @WORDS = qw(car cars cat cats do dog);

# The SHA-256 of that list as a file, newlines included. Pinned rather
# than computed, so that a test can assemble the artifact on a perl too
# old to have Digest::SHA; t/01-format.t checks it against Digest::SHA
# wherever that module is present.
my $DIGEST_HEX = '10ba9f4f808581eb7edf9a261d88af8d443baf9927995583a63095aafe554b04';

# The records, index 1 upwards. Index 0 is the sentinel and is zero.
# [ letter, terminal, last, child ], exactly as the plan's table.
my @RECORDS = (
    [ 's', 1, 1, 0 ],   # 1  state R:     s to S, "cars" and "cats"
    [ 'r', 1, 0, 1 ],   # 2  state A:     r to R, "car"
    [ 't', 1, 1, 1 ],   # 3  state A:     t to R, "cat". The share
    [ 'a', 0, 1, 2 ],   # 4  state C:     a to A
    [ 'g', 1, 1, 0 ],   # 5  state O:     g to S, "dog"
    [ 'o', 1, 1, 5 ],   # 6  state D:     o to O, "do"
    [ 'c', 0, 0, 4 ],   # 7  start:       c to C
    [ 'd', 0, 1, 6 ],   # 8  start:       d to D
);

my $ROOT = 7;

my %CONST;

# The header's #defines, as numbers and strings. A define this parser
# cannot read is a define nothing can rely on, so it is skipped and the
# test's own pin list is what notices it went missing.
sub constants {
    return { %CONST } if %CONST;
    my $path = _header_path();
    open my $fh, '<', $path or die "FRDTest::Vector: cannot read $path: $!\n";
    while (my $line = <$fh>) {
        next unless $line =~ /\A\s*#\s*define\s+(FRD_\w+)\s+(\S.*?)\s*\z/;
        my ($name, $value) = ($1, $2);
        $value =~ s{/\*.*}{};
        $value =~ s/\s+\z//;
        if ($value =~ /\A"(.*)"\z/) {
            my $string = $1;
            $string =~ s/\\n/\n/g;
            $CONST{$name} = $string;
        }
        elsif ($value =~ /\A0[xX]([0-9a-fA-F]+)U?\z/) {
            $CONST{$name} = hex $1;
        }
        elsif ($value =~ /\A([0-9]+)U?\z/) {
            $CONST{$name} = $1 + 0;
        }
    }
    close $fh;
    return { %CONST };
}

sub words       { return @WORDS }
sub list_bytes  { return join '', map { "$_\n" } @WORDS }
sub digest_hex  { return $DIGEST_HEX }
sub root        { return $ROOT }
sub node_count  { return scalar(@RECORDS) + 1 }

# The hand table, as a list of [ letter, terminal, last, child ] with
# index 0 prepended as the sentinel.
sub records {
    return ( [ '', 0, 0, 0 ], map { [ @$_ ] } @RECORDS );
}

# One record, packed from the header's bit layout and nothing else.
sub record_value {
    my ($letter, $terminal, $last, $child) = @_;
    my $c = constants();
    my $n = $letter eq '' ? 0 : ord($letter) - ord('a') + 1;
    return $n
         | ($terminal ? $c->{FRD_TERMINAL_BIT} : 0)
         | ($last     ? $c->{FRD_LAST_BIT}     : 0)
         | ($child << $c->{FRD_CHILD_SHIFT});
}

# The hundred bytes.
sub artifact {
    my $c = constants();
    my $out = $c->{FRD_MAGIC}
            . pack('V', $c->{FRD_FORMAT})
            . pack('V', node_count())
            . pack('V', scalar @WORDS)
            . pack('V', $ROOT)
            . pack('V', 0)
            . pack('V', 0)
            . pack('H*', $DIGEST_HEX);
    die 'FRDTest::Vector: the header is not FRD_HEADER_LEN bytes'
        unless length($out) == $c->{FRD_HEADER_LEN};
    for my $r (records()) {
        $out .= pack 'V', record_value(@$r);
    }
    return $out;
}

# Run from t/ or from the distribution root, and say which file it
# wanted when it finds neither.
sub _header_path {
    for my $path ($HEADER, "../$HEADER") {
        return $path if -f $path;
    }
    die "FRDTest::Vector: cannot find $HEADER from " . _cwd() . "\n";
}

sub _cwd {
    require Cwd;
    return Cwd::getcwd();
}

1;

__END__

=head1 NAME

FRDTest::Vector - the six word automaton, by hand

=head1 DESCRIPTION

The fixed point every other test in this distribution is measured
against: the word list, the record table and the artifact bytes of
C<plan_file_raw_dawg/01-the-format.md>, written by hand, with the
format's own numbers parsed out of F<include/file_raw_dawg.h> so that
there is one normative copy of them.

=cut
