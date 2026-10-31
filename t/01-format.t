#!perl
use 5.008003;
use strict;
use warnings;
use Test::More;
use FindBin ();
use lib "$FindBin::Bin/lib";
use FRDTest::Vector ();
use FRDTest::Reference ();

# plan_file_raw_dawg/01-the-format.md.
#
# The format, pinned. Every number here is HAND: it was written into the
# plan before any code existed, and this file asserts that the header
# still says it and that the hundred bytes of the six word automaton are
# still those hundred bytes.
#
# Nothing in this file calls the builder or the XS reader. The two halves
# that will (the builder's output, and the XS refusing a bad artifact)
# declare themselves below and skip until phases 02 and 03 land.

my $C = FRDTest::Vector::constants();

subtest 'the header is the normative copy of the format' => sub {
    # HAND: the plan's table, restated here so that a header edited by
    # accident fails a test rather than moving the format quietly.
    my %pin = (
        FRD_MAGIC        => "FRDAWG1\n",
        FRD_MAGIC_LEN    => 8,
        FRD_FORMAT       => 1,
        FRD_OFF_MAGIC    => 0,
        FRD_OFF_FORMAT   => 8,
        FRD_OFF_NODES    => 12,
        FRD_OFF_WORDS    => 16,
        FRD_OFF_ROOT     => 20,
        FRD_OFF_FLAGS    => 24,
        FRD_OFF_RESERVED => 28,
        FRD_OFF_DIGEST   => 32,
        FRD_DIGEST_LEN   => 32,
        FRD_HEADER_LEN   => 64,
        FRD_REC_LEN      => 4,
        FRD_LETTER_MASK  => 0x1F,
        FRD_TERMINAL_BIT => 0x20,
        FRD_LAST_BIT     => 0x40,
        FRD_CHILD_SHIFT  => 7,
        FRD_MAX_NODES    => 0x1FFFFFF,
        FRD_MIN_LETTER   => 1,
        FRD_MAX_LETTER   => 26,
        FRD_FLAG_COUNTED => 1,
        FRD_FLAGS_KNOWN  => 0,
    );
    for my $name (sort keys %pin) {
        is($C->{$name}, $pin{$name}, "$name is " . _show($pin{$name}));
    }

    # The magic ends in a newline on purpose: a transfer that rewrites
    # line endings must break the magic, not shift every record.
    like($C->{FRD_MAGIC}, qr/\n\z/, 'the magic ends in a newline');
    is(length $C->{FRD_MAGIC}, $C->{FRD_MAGIC_LEN}, 'the magic is its stated length');

    # The record's four fields tile a 32 bit word with nothing spare.
    my $letter_bits = 0;
    $letter_bits++ while (1 << $letter_bits) <= $C->{FRD_LETTER_MASK};
    is($letter_bits, 5, 'the letter is five bits');
    is($C->{FRD_TERMINAL_BIT}, 1 << $letter_bits, 'terminal is the bit above the letter');
    is($C->{FRD_LAST_BIT}, $C->{FRD_TERMINAL_BIT} << 1, 'last is the bit above terminal');
    is($C->{FRD_CHILD_SHIFT}, $letter_bits + 2, 'the child starts above both flags');
    is($C->{FRD_MAX_NODES}, (1 << (32 - $C->{FRD_CHILD_SHIFT})) - 1,
        'the child index is the rest of the word');
    cmp_ok($C->{FRD_MAX_LETTER}, '<=', $C->{FRD_LETTER_MASK},
        'the alphabet fits in the letter field');

    is($C->{FRD_OFF_DIGEST} + $C->{FRD_DIGEST_LEN}, $C->{FRD_HEADER_LEN},
        'the digest ends the header');
};

my $ART = FRDTest::Vector::artifact();

subtest 'the six word artifact is a hundred bytes' => sub {
    is(length $ART, 100, 'a hundred bytes');
    is(length $ART, $C->{FRD_HEADER_LEN} + $C->{FRD_REC_LEN} * 9,
        'which is the header plus nine records');

    is(substr($ART, $C->{FRD_OFF_MAGIC}, $C->{FRD_MAGIC_LEN}), "FRDAWG1\n", 'the magic');
    is(_u32($ART, $C->{FRD_OFF_FORMAT}),   1, 'format 1');
    is(_u32($ART, $C->{FRD_OFF_NODES}),    9, 'nine records, the sentinel included');
    is(_u32($ART, $C->{FRD_OFF_WORDS}),    6, 'six words');
    is(_u32($ART, $C->{FRD_OFF_ROOT}),     7, 'the start state begins at record 7');
    is(_u32($ART, $C->{FRD_OFF_FLAGS}),    0, 'no flags');
    is(_u32($ART, $C->{FRD_OFF_RESERVED}), 0, 'nothing reserved');

    is(unpack('H*', substr($ART, $C->{FRD_OFF_DIGEST}, $C->{FRD_DIGEST_LEN})),
        FRDTest::Vector::digest_hex(), 'the source list digest');

    is(_u32($ART, $C->{FRD_HEADER_LEN}), 0, 'record 0 is the sentinel');
};

subtest 'every record is the value the plan worked out' => sub {
    # HAND: plan_file_raw_dawg/01-the-format.md, the table of nine rows.
    # index => [ value, the four little-endian bytes ]
    my @want = (
        [   0, '00 00 00 00' ],
        [ 115, '73 00 00 00' ],
        [ 178, 'b2 00 00 00' ],
        [ 244, 'f4 00 00 00' ],
        [ 321, '41 01 00 00' ],
        [ 103, '67 00 00 00' ],
        [ 751, 'ef 02 00 00' ],
        [ 515, '03 02 00 00' ],
        [ 836, '44 03 00 00' ],
    );
    for my $i (0 .. $#want) {
        my $at    = $C->{FRD_HEADER_LEN} + $C->{FRD_REC_LEN} * $i;
        my $bytes = join ' ', map { sprintf '%02x', $_ }
                              unpack 'C*', substr($ART, $at, $C->{FRD_REC_LEN});
        is(_u32($ART, $at), $want[$i][0], "record $i is $want[$i][0]");
        is($bytes, $want[$i][1], "record $i is $want[$i][1]");
    }
};

subtest 'the four walks the plan worked by hand' => sub {
    my $d = FRDTest::Reference->new($ART);

    is($d->root, 7, 'the walk starts at record 7');
    is($d->node_count, 9, 'nine records');
    is($d->word_count, 6, 'six words');

    # cat: record 7 is c, then 4 is a, then the group at 2 holds r and
    # is not last, so the scan steps to 3, which is t and terminal.
    ok($d->contains('cat'), 'cat is accepted');
    is_deeply($d->trace('cat'), [ 7, 4, 3 ], 'cat walks 7, 4, 3');

    # ca: ends at record 4, whose terminal bit is clear, and whose child
    # is 2, so it is a prefix and not a word.
    ok(!$d->contains('ca'), 'ca is not a word');
    ok($d->has_prefix('ca'), 'ca is a prefix');

    # cars and cats: both reach the same record 1. The share is the
    # whole point of the structure and it is visible in the trace.
    ok($d->contains('cars'), 'cars is accepted');
    ok($d->contains('cats'), 'cats is accepted');
    is_deeply($d->trace('cars'), [ 7, 4, 2, 1 ], 'cars walks 7, 4, 2, 1');
    is_deeply($d->trace('cats'), [ 7, 4, 3, 1 ], 'cats walks 7, 4, 3, 1');
    is($d->trace('cars')->[-1], $d->trace('cats')->[-1],
        'cars and cats end on the same record');

    # dot: record 8 is d, then 6 is o, then the group at 5 holds g
    # alone and is last, so the scan is exhausted.
    ok(!$d->contains('dot'), 'dot is refused');
    is($d->trace('dot'), undef, 'dot has no path');
};

subtest 'every word, every prefix, and twenty refusals' => sub {
    my $d = FRDTest::Reference->new($ART);

    ok($d->contains($_), "$_ is accepted") for FRDTest::Vector::words();

    my %prefix;
    for my $w (FRDTest::Vector::words()) {
        $prefix{substr $w, 0, $_} = 1 for 1 .. length($w) - 1;
    }
    ok($d->has_prefix($_), "$_ is a prefix") for sort keys %prefix;
    ok($d->has_prefix(''), 'the empty prefix is a prefix');

    # HAND: each refused for a reason written beside it.
    my %refuse = (
        'ca'      => 'a prefix, not a word',
        'c'       => 'a prefix, not a word',
        'd'       => 'a prefix, not a word',
        'dot'     => 'the group after do holds only g',
        'cart'    => 'the group after car holds only s',
        'care'    => 'the group after car holds only s',
        'dogs'    => 'g has no children',
        'cas'     => 'the group after ca holds r and t',
        'rat'     => 'the start state holds only c and d',
        'at'      => 'the start state holds only c and d',
        'ct'      => 'c is followed only by a',
        'do g'    => 'a space is not a letter',
        'DOG'     => 'the alphabet is lower case',
        'dog '    => 'a trailing space is not a letter',
        ''        => 'the empty word',
        'cats!'   => 'punctuation is not a letter',
        'cars1'   => 'a digit is not a letter',
        'zebra'   => 'z is not in the start state',
        'carsx'   => 's has no children',
        'catsy'   => 's has no children',
    );
    ok(!$d->contains($_), "$_ is refused: $refuse{$_}") for sort keys %refuse;
};

subtest 'the pinned digest is the digest of the list' => sub {
    # Pinned rather than computed, so the vector assembles on a perl with
    # no Digest::SHA. Where the module is present, it is checked.
    if (!eval { require Digest::SHA; 1 }) {
        plan skip_all => 'Digest::SHA is not installed on this perl';
    }
    plan tests => 2;
    my $list = FRDTest::Vector::list_bytes();
    is($list, "car\ncars\ncat\ncats\ndo\ndog\n", 'the list, sorted, one word a line');
    is(Digest::SHA::sha256_hex($list), FRDTest::Vector::digest_hex(),
        'the pinned digest is right');
};

subtest 'the eight refusals, against the reference reader' => sub {
    # The reference reader implements the format's validation, so the
    # refusal list can be pinned now. The XS reader must refuse the same
    # eight, with the same eight distinct messages: that is
    # plan_file_raw_dawg/03, t/03-open-refusals.t.
    my @bad = (
        [ 'bad magic',        _splice($ART, 0, 'XRDAWG1' . "\n"),  qr/magic/ ],
        [ 'CRLF magic',       _splice($ART, 0, "FRDAWG1\r"),       qr/line endings/ ],
        [ 'format 2',         _splice($ART, 8, pack 'V', 2),       qr/format/ ],
        [ 'a flag set',       _splice($ART, 24, pack 'V', 1),      qr/flags/ ],
        [ 'a half record',    $ART . "\0\0",                       qr/whole number of records/ ],
        [ 'node_count wrong', _splice($ART, 12, pack 'V', 8),      qr/node_count/ ],
        [ 'live record 0',    _splice($ART, 64, pack 'V', 115),    qr/sentinel/ ],
        [ 'root past the end',_splice($ART, 20, pack 'V', 9),      qr/root/ ],
    );
    plan tests => 2 * @bad + 1;

    my %seen;
    for my $case (@bad) {
        my ($what, $bytes, $like) = @$case;
        my $d = eval { FRDTest::Reference->new($bytes) };
        ok(!$d, "$what is refused");
        like($@, $like, "$what says why");
        $seen{$@} = 1;
    }
    is(scalar keys %seen, scalar @bad, 'eight refusals, eight distinct messages');
};

subtest 'the builder emits these bytes' => sub {
    plan skip_all => 'the builder is plan_file_raw_dawg/02'
        unless eval { require File::Raw::DAWG; File::Raw::DAWG->can('build') };
    plan tests => 2;

    # The vector is the expected value and the builder's output is the
    # actual one, never the other way round.
    require FRDTest::Tmp;
    my $dir  = FRDTest::Tmp::dir();
    my $list = "$dir/six-words.txt";
    my $art  = "$dir/six-words.dawg";
    FRDTest::Tmp::spew($list, FRDTest::Vector::list_bytes());

    my $built = File::Raw::DAWG->build($list, $art);
    is($built->{bytes}, 100, 'the builder writes a hundred bytes');
    is(FRDTest::Tmp::slurp($art), $ART, 'and they are these hundred bytes');
};

done_testing();

sub _u32 {
    my ($bytes, $at) = @_;
    return unpack 'V', substr($bytes, $at, 4);
}

sub _splice {
    my ($bytes, $at, $with) = @_;
    substr($bytes, $at, length $with) = $with;
    return $bytes;
}

sub _show {
    my ($v) = @_;
    return '"' . join('', map { $_ eq "\n" ? '\\n' : $_ } split //, $v) . '"'
        if $v =~ /\D/;
    return $v;
}
