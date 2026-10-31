#!perl
use 5.008003;
use strict;
use warnings;
use Test::More;
use FindBin ();
use lib "$FindBin::Bin/lib";
use FRDTest::Tmp ();

# plan_file_raw_dawg/05-portability.md.
#
# The floors, checked by a test rather than by a person remembering.
# Everything here is a trap this house has already paid for once, and
# every one of them is invisible on the machine the code was written on:
# they only appear on an old compiler, an old perl, or Windows. So they
# are asserted here, where they cost nothing, instead of being found by
# a smoker three weeks later.

my $root = -d 'include' ? '.' : '..';

my @C_SOURCES = grep { -f } map { "$root/$_" }
                qw(dawg_build.c dawg_build.h include/file_raw_dawg.h DAWG.xs t/abi/walk.c);

plan tests => 9;

ok(scalar @C_SOURCES, 'found the C sources') or diag("looked under $root");

subtest 'the perl floor is declared everywhere and is one number' => sub {
    my @perl = grep { -f } map { "$root/$_" }
               ('lib/File/Raw/DAWG.pm', 'Makefile.PL',
                glob("$root/t/*.t"), glob("$root/t/lib/FRDTest/*.pm"));
    plan tests => scalar(@perl) + 1;

    for my $file (@perl) {
        my $text = FRDTest::Tmp::slurp($file);
        like($text, qr/^use 5\.008003;/m, "$file declares the floor");
    }

    my $mk = FRDTest::Tmp::slurp("$root/Makefile.PL");
    like($mk, qr/MIN_PERL_VERSION\s*=>\s*'5\.008003'/,
        'and Makefile.PL agrees with it');
};

subtest 'no syntax newer than the floor' => sub {
    my @perl = grep { -f } map { "$root/$_" }
               ('lib/File/Raw/DAWG.pm', glob("$root/t/lib/FRDTest/*.pm"));
    plan tests => scalar @perl;

    # 5.10 and later, each of which compiles here and dies on 5.8.
    #
    # The defined-or pattern is deliberately narrow. `//` is not a token
    # a regex can find in perl source: `s/\s+\z//` and `split //` both
    # contain it and neither is defined-or. What is unambiguous is the
    # assignment form, and an expression followed by a spaced `//`.
    my @newer = (
        [ qr{//=|[\$\w\)\]]\s+//\s}  => 'the defined-or operator' ],
        [ qr/^\s*say\b/m             => 'say' ],
        [ qr/~~/                     => 'smartmatch' ],
        [ qr/^\s*state\s+[\$\@\%]/m  => 'state variables' ],
        [ qr/use feature/            => 'use feature' ],
        [ qr/sub\s+\w+\s*\([\$\@\%]\w/ => 'subroutine signatures' ],
    );
    for my $file (@perl) {
        my $text = FRDTest::Tmp::slurp($file);
        $text =~ s/^__END__.*//sm;         # the pod is not code
        $text =~ s/^\s*#.*$//mg;           # nor are comments
        my @found = map { $_->[1] } grep { $text =~ $_->[0] } @newer;
        is_deeply(\@found, [], "$file uses nothing newer than 5.8");
    }
};

subtest 'the C is C89' => sub {
    plan tests => 3 * @C_SOURCES;
    for my $file (@C_SOURCES) {
        my $text = FRDTest::Tmp::slurp($file);
        # The comments say "no long long" and "no //", which is not the
        # same as using them, so the comments go before the checks run.
        $text =~ s{/\*.*?\*/}{}gs;
        unlike($text, qr{^\s*//}m, "$file has no // comments");
        unlike($text, qr/\blong\s+long\b/, "$file has no long long");
        unlike($text, qr/%ll[uxd]/, "$file has no %ll format");
    }
};

subtest 'no identifier windows.h has taken' => sub {
    # windows.h defines these as macros, so a parameter or a member
    # named after one of them breaks on Windows and nowhere else.
    my @taken = qw(near far small IN OUT OPTIONAL CONST);
    plan tests => scalar @C_SOURCES;

    for my $file (@C_SOURCES) {
        my $text = FRDTest::Tmp::slurp($file);
        $text =~ s{/\*.*?\*/}{}gs;         # comments may say the words
        my @hit = grep { $text =~ /\b\Q$_\E\s*[;,\)\[=]/ } @taken;
        is_deeply(\@hit, [], "$file uses none of them as an identifier");
    }
};

subtest 'nothing that needs a newer libc or a link flag' => sub {
    plan tests => scalar @C_SOURCES;
    # Each of these has cost this house a smoker: atomics need a new
    # gcc, clock_gettime needs -lrt on old glibc, stdint.h is C99.
    for my $file (@C_SOURCES) {
        my $text = FRDTest::Tmp::slurp($file);
        $text =~ s{/\*.*?\*/}{}gs;
        my @hit;
        push @hit, 'atomics'        if $text =~ /__atomic|__sync_|<stdatomic/;
        push @hit, 'clock_gettime'  if $text =~ /clock_gettime/;
        push @hit, 'stdint.h'       if $text =~ /<stdint\.h>/;
        push @hit, 'pthreads'       if $text =~ /<pthread\.h>/;
        is_deeply(\@hit, [], "$file needs none of them");
    }
};

subtest 'the header is in depend for every object' => sub {
    my $mk = FRDTest::Tmp::slurp("$root/Makefile.PL");
    plan tests => 3;
    like($mk, qr/depend\s*=>/, 'there is a depend block');
    like($mk, qr/\@HEADERS.*file_raw_dawg\.h/s, 'the public header is in it');
    # Make does not read #include lines. Without this, a format edit
    # ships against stale objects and every test still passes.
    my ($block) = $mk =~ /depend\s*=>\s*\{(.*?)\}/s;
    my @objects = $block ? $block =~ /'([^']+\$\(OBJ_EXT\))'/g : ();
    is(scalar @objects, 2, 'and both objects depend on it')
        or diag("found: @objects");
};

subtest 'the XS keeps its side of the perl API' => sub {
    my $xs = FRDTest::Tmp::slurp("$root/DAWG.xs");
    plan tests => 3;
    # A bare SvPV or SvPV_nolen loses the length, which is how a NUL in
    # the middle of a word becomes a shorter word.
    unlike($xs, qr/SvPV_nolen|SvPV\s*\([^,)]+\)/, 'no SvPV without its length');
    # Mortalising RETVAL as well as returning it frees it twice.
    unlike($xs, qr/RETVAL\s*=\s*sv_2mortal/, 'RETVAL is not mortalised');
    like($xs, qr/PERL_NO_GET_CONTEXT/, 'and the context is not fetched per call');
};

subtest 'Changes names this version' => sub {
    plan tests => 2;
    my $pm = FRDTest::Tmp::slurp("$root/lib/File/Raw/DAWG.pm");
    my ($version) = $pm =~ /\$VERSION\s*=\s*'([^']+)'/;
    ok($version, 'the module has a $VERSION');
    my $changes = FRDTest::Tmp::slurp("$root/Changes");
    like($changes, qr/^\Q$version\E\s/m, "Changes has an entry for $version");
};
