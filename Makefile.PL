use 5.008003;
use strict;
use warnings;
use ExtUtils::MakeMaker;
use ExtUtils::Depends;

# This distribution is a provider: include/file_raw_dawg.h is the whole
# format and the whole walk, header only, with no Perl in it, and it is
# installed so that another XS distribution can hold the same mapping
# and walk the same records without paying for an XSUB call per edge.
#
# It consumes nothing through ExtUtils::Depends. File::Raw is a runtime
# prerequisite (each_line streams the list, mmap_open maps the
# artifact), not a compile-time one: no C of ours calls any C of its.
my $pkg = ExtUtils::Depends->new('File::Raw::DAWG');
$pkg->set_inc('-Iinclude -I.');
$pkg->install('include/file_raw_dawg.h');
mkdir 'Install' unless -d 'Install';
$pkg->save_config('Install/Files.pm');

# The header is in `depend` for both objects. A changed file_raw_dawg.h
# that does not rebuild them is this house's oldest build bug: make does
# not read #include lines, so without this a format edit ships against
# stale objects and every test still passes.
my @HEADERS = ('include/file_raw_dawg.h', 'dawg_build.h');

my %WriteMakefileArgs = (
    NAME             => 'File::Raw::DAWG',
    AUTHOR           => ['LNATION <email@lnation.org>'],
    VERSION_FROM     => 'lib/File/Raw/DAWG.pm',
    ABSTRACT_FROM    => 'lib/File/Raw/DAWG.pm',
    LICENSE          => 'artistic_2',
    MIN_PERL_VERSION => '5.008003',
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => '0',
    },
    TEST_REQUIRES => {
        'Test::More' => '0',
    },
    PREREQ_PM => {
        # each_line streams the list. Digest::SHA is core from 5.9.3 and
        # this distribution's floor is older, so it is declared rather
        # than assumed.
        'File::Raw'   => '0.15',
        'Digest::SHA' => '0',
    },
    INC    => '-Iinclude -I.',
    OBJECT => 'DAWG$(OBJ_EXT) dawg_build$(OBJ_EXT)',
    C      => ['dawg_build.c'],
    XS     => { 'DAWG.xs' => 'DAWG.c' },
    depend => {
        'DAWG$(OBJ_EXT)'       => join(' ', @HEADERS),
        'dawg_build$(OBJ_EXT)' => join(' ', @HEADERS),
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    $pkg->get_makefile_vars,
    clean => { FILES => 'File-Raw-DAWG-* DAWG.c DAWG.bs DAWG$(OBJ_EXT) '
                      . 'dawg_build$(OBJ_EXT) Install/Files.pm' },
);

# ExtUtils::Depends' PM map (installing the header and Files.pm)
# REPLACES MakeMaker's auto-detected PM, so the module's own .pm files
# have to be put back. Without this, DAWG.pm itself stops installing the
# moment the header starts to: the house gotcha, and File-Raw-Hash's
# Makefile.PL carries the same paragraph for the same reason.
{
    require File::Find;
    File::Find::find(sub {
        return unless /\.pm\z/;
        (my $rel = $File::Find::name) =~ s{^lib/}{};
        $WriteMakefileArgs{PM}{$File::Find::name} = "\$(INST_LIB)/$rel";
    }, 'lib');
}

# Compatibility with old versions of ExtUtils::MakeMaker
unless (eval { ExtUtils::MakeMaker->VERSION('6.64'); 1 }) {
    my $test_requires = delete $WriteMakefileArgs{TEST_REQUIRES} || {};
    @{$WriteMakefileArgs{PREREQ_PM}}{keys %$test_requires} = values %$test_requires;
}

unless (eval { ExtUtils::MakeMaker->VERSION('6.55_03'); 1 }) {
    my $build_requires = delete $WriteMakefileArgs{BUILD_REQUIRES} || {};
    @{$WriteMakefileArgs{PREREQ_PM}}{keys %$build_requires} = values %$build_requires;
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
    unless eval { ExtUtils::MakeMaker->VERSION('6.52'); 1 };
delete $WriteMakefileArgs{MIN_PERL_VERSION}
    unless eval { ExtUtils::MakeMaker->VERSION('6.48'); 1 };
delete $WriteMakefileArgs{LICENSE}
    unless eval { ExtUtils::MakeMaker->VERSION('6.31'); 1 };

WriteMakefile(%WriteMakefileArgs);
