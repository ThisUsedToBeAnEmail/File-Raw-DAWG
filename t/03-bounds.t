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
# THE FILE THE DESIGN EXISTS FOR.
#
# A walk is a loop of "follow this index", so an index that is not
# checked is a read at an arbitrary offset from the mapping. These
# artifacts have valid headers and corrupt insides: `open` accepts every
# one of them, and the walk is what must refuse.
#
# Every case runs in a child process, because the failure this is
# guarding against is a segfault and a segfault in the parent would look
# like a missing plan.

my $C = FRDTest::Vector::constants();

# Record 7 is the start state's `c`, whose child is the state at 4.
my $REC7 = $C->{FRD_HEADER_LEN} + $C->{FRD_REC_LEN} * 7;
my $REC8 = $C->{FRD_HEADER_LEN} + $C->{FRD_REC_LEN} * 8;

my @CASE = (
    {
        name  => 'a child index one past the end',
        edit  => sub { _rewrite($_[0], $REC7, 'c', 0, 0, 9) },
        probe => sub { $_[0]->contains('cat') },
        like  => qr/walk left the records/,
    },
    {
        name  => 'a child index of thirty three million',
        edit  => sub { _rewrite($_[0], $REC7, 'c', 0, 0, $C->{FRD_MAX_NODES}) },
        probe => sub { $_[0]->contains('cat') },
        like  => qr/walk left the records/,
    },
    {
        name  => 'a final record with its last bit cleared',
        edit  => sub { _rewrite($_[0], $REC8, 'd', 0, 0, 6) },
        probe => sub { $_[0]->contains('zoo') },
        like  => qr/walk left the records/,
    },
    {
        name  => 'a group that runs off the end, walked by children',
        edit  => sub { _rewrite($_[0], $REC8, 'd', 0, 0, 6) },
        probe => sub { $_[0]->children($_[0]->root) },
        like  => qr/walk left the records/,
    },
    {
        name  => 'a record whose letter is 0, decoded by children',
        edit  => sub { _rewrite($_[0], $REC7, undef, 0, 0, 4) },
        probe => sub { $_[0]->children($_[0]->root) },
        like  => qr/walk left the records/,
    },
    {
        name  => 'a record whose letter is 27, decoded by children',
        edit  => sub { _rewrite($_[0], $REC7, 27, 0, 0, 4) },
        probe => sub { $_[0]->children($_[0]->root) },
        like  => qr/walk left the records/,
    },
);

plan tests => 3 * @CASE + 3 + 7;

my $dir  = FRDTest::Tmp::dir();
my $good = FRDTest::Vector::artifact();
my $n    = 0;

for my $case (@CASE) {
    $n++;
    my $art = "$dir/bent-$n.dawg";
    FRDTest::Tmp::spew($art, $case->{edit}->($good));

    # The header is still valid: these are corrupt insides, not a
    # corrupt header, which is what makes them the walk's problem.
    my $opened = eval { File::Raw::DAWG->open($art); 1 };
    ok($opened, "$case->{name}: the header still opens") or diag($@);

    my ($status, $output) = _in_a_child($art, $n);
    is($status & 127, 0, "$case->{name}: no crash")
        or diag('killed by signal ' . ($status & 127));
    like($output, $case->{like}, "$case->{name}: croaks, and says what happened");
}

# An impossible letter cannot cause an unsafe read, so the matching path
# treats it as a letter nobody asked for rather than paying for a check
# per record in the hot loop. It is the decoding path, children, that
# refuses. Asserted rather than left implied, because the plan said
# "each croaks" and this is the one that does not.
{
    my $art = "$dir/letter-zero.dawg";
    FRDTest::Tmp::spew($art, _rewrite($good, $REC7, undef, 0, 0, 4));
    my $d = File::Raw::DAWG->open($art);
    my $answer = eval { $d->contains('cat') };
    is($@, '', 'a record with an impossible letter does not croak the match path');
    is($answer, 0, 'it simply matches nothing');
    is(eval { $d->contains('do') }, 1, 'and the rest of the automaton still works');
}

# A handle is a plain integer, so nothing stops one being made up, or
# being carried over from a different reader. Every entry point refuses
# one that is not a record of THIS artifact, because the alternative is
# a lookup that quietly answers about the wrong thing.
{
    my $art = "$dir/good.dawg";
    FRDTest::Tmp::spew($art, $good);
    my $d = File::Raw::DAWG->open($art);
    my $past = $d->node_count + 400;

    my @entry = (
        [ 'child'       => sub { $d->child($past, 'c') } ],
        [ 'step'        => sub { $d->step($past, 'c') } ],
        [ 'children'    => sub { $d->children($past) } ],
        [ 'is_terminal' => sub { $d->is_terminal($past) } ],
        [ 'next_node'   => sub { $d->next_node($past) } ],
    );
    for my $e (@entry) {
        my ($name, $call) = @$e;
        eval { $call->() };
        like($@, qr/walk left the records/, "$name refuses a handle past the end");
    }

    # Group 0 is not out of range: it is the empty state, and asking it
    # for a letter is a fair question with the answer no.
    is(eval { $d->child(0, 'c') }, undef, 'the empty state has no transitions');
    is($@, '', 'and asking it is not an error');
}

sub _in_a_child {
    my ($path, $which) = @_;
    my $probe = $which == 4 || $which == 5 || $which == 6
              ? 'File::Raw::DAWG->open($ARGV[0])->children(File::Raw::DAWG->open($ARGV[0])->root)'
              : $which == 3
              ? 'File::Raw::DAWG->open($ARGV[0])->contains("zoo")'
              : 'File::Raw::DAWG->open($ARGV[0])->contains("cat")';
    my $out = `$^X -Iblib/lib -Iblib/arch -MFile::Raw::DAWG -e '$probe' $path 2>&1`;
    return ($?, $out);
}

# Put a record back with fields of our choosing. A letter of undef means
# 0, the sentinel's letter, which no real record may carry.
sub _rewrite {
    my ($bytes, $at, $letter, $terminal, $last, $child) = @_;
    my $code = !defined $letter ? 0
             : $letter =~ /\A[0-9]+\z/ ? $letter
             : ord($letter) - ord('a') + 1;
    my $v = $code
          | ($terminal ? $C->{FRD_TERMINAL_BIT} : 0)
          | ($last     ? $C->{FRD_LAST_BIT}     : 0)
          | ($child << $C->{FRD_CHILD_SHIFT});
    substr($bytes, $at, 4) = pack 'V', $v;
    return $bytes;
}
