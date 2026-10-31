#!perl
use 5.008003;
use strict;
use warnings;
use Test::More;

unless ( $ENV{RELEASE_TESTING} ) {
    plan( skip_all => "Author tests not required for installation" );
}

# Ensure a recent version of Test::Pod::Coverage
my $min_tpc = 1.08;
eval "use Test::Pod::Coverage $min_tpc";
plan skip_all => "Test::Pod::Coverage $min_tpc required for testing POD coverage"
    if $@;

# Test::Pod::Coverage doesn't require a minimum Pod::Coverage version,
# but older versions don't recognize some common documentation styles
my $min_pc = 0.18;
eval "use Pod::Coverage $min_pc";
plan skip_all => "Pod::Coverage $min_pc required for testing POD coverage"
    if $@;

# NOT all_pod_coverage_ok(), which Module::Starter wrote here and which
# cannot pass in a distribution shaped like this one.
#
# It walks blib/arch as well as blib/lib, and blib/arch holds
# File/Raw/DAWG/Install/Files.pm, which ExtUtils::Depends GENERATES so
# that consumers can find the installed header. It is not ours, it has
# no pod, and it never will have. A test that can only fail is no better
# than one that can only pass: both teach you to stop reading it.
#
# It also needs a built tree, because Pod::Coverage has to load a module
# to see its symbol table and this one has XS in it.
plan skip_all => 'needs a built tree: run make first'
    unless -d 'blib/lib' || -d '../blib/lib';

# all_modules() with no argument is the one that names modules properly
# (File::Raw::DAWG, not blib::lib::File::Raw::DAWG). It also reaches
# into blib/arch, where it finds the generated Files.pm and calls it
# `arch::File::Raw::DAWG::Install::Files`. That name is the tell: it is
# not a module anybody wrote, so it is dropped here by the only thing
# that identifies it, and everything else is tested.
my @modules = grep { !/::Install::Files\z/ } all_modules();
plan skip_all => 'no modules found' unless @modules;
plan tests => scalar @modules;

pod_coverage_ok($_) for @modules;
