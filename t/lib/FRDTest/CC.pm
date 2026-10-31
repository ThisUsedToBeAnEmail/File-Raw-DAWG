package FRDTest::CC;

use 5.008003;
use strict;
use warnings;

use Config ();
use File::Spec ();

our $VERSION = '0.01';

# Compiling t/abi/walk.c against the INSTALLED header and nothing else.
#
# The point of the ABI tests is that a consumer needs this distribution's
# header and no knowledge of its insides, so the command line here
# carries exactly one -I and never perl's.

# Where `make` put the installed header. This is what a consumer finds
# through File::Raw::DAWG::Install::Files, and it is deliberately NOT
# the source tree's include/: a header that is right in the tree and
# wrong once installed would pass a test that looked there.
sub header_dir {
    for my $base ('blib/arch', File::Spec->catdir('..', 'blib', 'arch')) {
        my $dir = File::Spec->catdir($base, 'File', 'Raw', 'DAWG', 'Install');
        return $dir if -f File::Spec->catfile($dir, 'file_raw_dawg.h');
    }
    return undef;
}

sub source {
    for my $path ('t/abi/walk.c', 'abi/walk.c') {
        return $path if -f $path;
    }
    return undef;
}

sub compiler { return $Config::Config{cc} }

# Compile, returning the executable's path or undef plus the output.
# Warnings are errors where the compiler understands the flags: a public
# header that cannot be included without warnings is not finished.
sub build {
    my ($dir) = @_;
    my $src = source()     or return (undef, "t/abi/walk.c is missing\n");
    my $inc = header_dir() or return (undef, "the installed header is missing: run make\n");
    my $cc  = compiler()   or return (undef, "no compiler in Config\n");

    my $exe = File::Spec->catfile($dir, 'walk');
    my @warn = $cc =~ /\b(?:gcc|clang|cc)\b/ ? ('-Wall', '-Wextra', '-Werror') : ();

    my $cmd = join ' ', $cc, @warn, "-I$inc", '-o', $exe, $src, '2>&1';
    my $out = `$cmd`;
    return ($? == 0 && -x $exe ? $exe : undef, "$cmd\n$out");
}

sub run {
    my ($exe, @args) = @_;
    my $out = `$exe @args 2>&1`;
    return $out;
}

1;

__END__

=head1 NAME

FRDTest::CC - compile a C consumer against the installed header

=head1 DESCRIPTION

Test plumbing for the ABI tests: finds the header where C<make> installed
it, finds a compiler, and builds F<t/abi/walk.c> with exactly one C<-I>
and none of perl's.

=cut
