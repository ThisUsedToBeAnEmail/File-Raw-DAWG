package FRDTest::Tmp;

use 5.008003;
use strict;
use warnings;

use File::Temp ();
use File::Spec ();

our $VERSION = '0.01';

# Somewhere to write a list and an artifact, and the two calls for
# putting bytes there and getting them back. Test plumbing only.
#
# The directory goes away with the process, which is also what stops a
# failed build leaving a half artifact behind for the next run to read.

my @KEEP;

sub dir {
    my $dir = File::Temp->newdir('frd-XXXXXX', TMPDIR => 1);
    push @KEEP, $dir;
    return "$dir";
}

sub spew {
    my ($path, $bytes) = @_;
    open my $fh, '>', $path or die "FRDTest::Tmp: cannot write $path: $!\n";
    binmode $fh;
    print {$fh} $bytes or die "FRDTest::Tmp: cannot write $path: $!\n";
    close $fh or die "FRDTest::Tmp: cannot close $path: $!\n";
    return $path;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "FRDTest::Tmp: cannot read $path: $!\n";
    binmode $fh;
    my $bytes = do { local $/; <$fh> };
    close $fh;
    return defined $bytes ? $bytes : '';
}

# A list file from a list of words, one a line, in the order given. The
# order is the caller's business: a test of the order check has to be
# able to write a list that is wrong.
sub list {
    my ($path, @words) = @_;
    return spew($path, join '', map { "$_\n" } @words);
}

1;

__END__

=head1 NAME

FRDTest::Tmp - a temporary directory and three file calls

=head1 DESCRIPTION

Test plumbing. A temporary directory that lasts as long as the process,
and C<spew>, C<slurp> and C<list> for putting bytes in it and taking
them out again.

=cut
