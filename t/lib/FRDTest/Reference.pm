package FRDTest::Reference;

use 5.008003;
use strict;
use warnings;

use FRDTest::Vector ();

our $VERSION = '0.01';

# A reader of the format in pure Perl, driven only by the constants in
# include/file_raw_dawg.h.
#
# It exists so that the format can be walked before any C is written,
# and afterwards so that the XS reader has something independent to
# disagree with. It is NOT the implementation and nothing outside t/
# should use it: it is slow, it holds the whole artifact in a scalar,
# and it bounds-checks by dying rather than by croaking usefully.
#
# It is deliberately written from the header's bit layout rather than
# from the hand table in FRDTest::Vector, so that a walk over that table
# is a check of the table and not a restatement of it.

sub new {
    my ($class, $bytes) = @_;
    my $c = FRDTest::Vector::constants();
    my $self = bless { bytes => $bytes, c => $c }, $class;

    die "reference: short file\n" if length($bytes) < $c->{FRD_HEADER_LEN};

    my $magic = substr $bytes, $c->{FRD_OFF_MAGIC}, $c->{FRD_MAGIC_LEN};
    if ($magic ne $c->{FRD_MAGIC}) {
        # The trailing newline in the magic exists to catch exactly one
        # thing, so when it is the only byte wrong, say which thing.
        my $stem = substr $c->{FRD_MAGIC}, 0, $c->{FRD_MAGIC_LEN} - 1;
        die "reference: line endings rewritten in transit\n"
            if index($magic, $stem) == 0;
        die "reference: bad magic\n";
    }

    $self->{format} = $self->_u32($c->{FRD_OFF_FORMAT});
    $self->{nodes}  = $self->_u32($c->{FRD_OFF_NODES});
    $self->{words}  = $self->_u32($c->{FRD_OFF_WORDS});
    $self->{root}   = $self->_u32($c->{FRD_OFF_ROOT});
    $self->{flags}  = $self->_u32($c->{FRD_OFF_FLAGS});

    die "reference: bad format\n" unless $self->{format} == $c->{FRD_FORMAT};
    die "reference: unknown flags\n" unless $self->{flags} == $c->{FRD_FLAGS_KNOWN};

    # Two ways for the length to be wrong, and they are told apart
    # because they mean different things: a file that is not a whole
    # number of records has been truncated or padded, and one whose
    # node_count disagrees has a rewritten header.
    die "reference: not a whole number of records\n"
        if (length($bytes) - $c->{FRD_HEADER_LEN}) % $c->{FRD_REC_LEN};
    die "reference: node_count disagrees with the length\n"
        unless length($bytes) == $c->{FRD_HEADER_LEN} + $c->{FRD_REC_LEN} * $self->{nodes};

    die "reference: record 0 is not the sentinel\n" if $self->{nodes} && $self->rec(0) != 0;

    # An empty automaton is the sentinel alone and its root is 0. Any
    # other artifact has a root that is a real record.
    if ($self->{nodes} == 1) {
        die "reference: root out of range\n" unless $self->{root} == 0;
    }
    else {
        die "reference: root out of range\n"
            if $self->{root} < 1 || $self->{root} >= $self->{nodes};
    }

    return $self;
}

sub _u32 {
    my ($self, $at) = @_;
    return unpack 'V', substr($self->{bytes}, $at, 4);
}

sub node_count { return $_[0]{nodes} }
sub word_count { return $_[0]{words} }
sub root       { return $_[0]{root} }

sub digest_hex {
    my ($self) = @_;
    my $c = $self->{c};
    return unpack 'H*', substr($self->{bytes}, $c->{FRD_OFF_DIGEST}, $c->{FRD_DIGEST_LEN});
}

sub rec {
    my ($self, $i) = @_;
    my $c = $self->{c};
    die "reference: record $i out of range\n" if $i >= $self->{nodes};
    return unpack 'V', substr($self->{bytes},
                              $c->{FRD_HEADER_LEN} + $c->{FRD_REC_LEN} * $i,
                              $c->{FRD_REC_LEN});
}

sub letter   { my ($s, $v) = @_; return $v & $s->{c}{FRD_LETTER_MASK} }
sub terminal { my ($s, $v) = @_; return ($v & $s->{c}{FRD_TERMINAL_BIT}) ? 1 : 0 }
sub last_bit { my ($s, $v) = @_; return ($v & $s->{c}{FRD_LAST_BIT}) ? 1 : 0 }
sub child    { my ($s, $v) = @_; return $v >> $s->{c}{FRD_CHILD_SHIFT} }

# The record in $group's run carrying $letter, or 0 for none. The scan is
# bounded by node_count as well as by the last bit, because last is one
# bit in a file anyone can edit.
sub step {
    my ($self, $group, $letter) = @_;
    return 0 unless $group;
    my $want = ord($letter) - ord('a') + 1;
    my $i = $group;
    while ($i < $self->{nodes}) {
        my $v = $self->rec($i);
        return $i if $self->letter($v) == $want;
        return 0 if $self->last_bit($v);
        $i++;
    }
    die "reference: group at $group runs past the end\n";
}

sub contains {
    my ($self, $word) = @_;
    return 0 unless defined $word && $word =~ /\A[a-z]+\z/;
    my $group = $self->{root};
    my @letters = split //, $word;
    while (@letters) {
        my $letter = shift @letters;
        my $at = $self->step($group, $letter);
        return 0 unless $at;
        my $v = $self->rec($at);
        return $self->terminal($v) unless @letters;
        $group = $self->child($v);
        return 0 unless $group;
    }
    return 0;
}

sub has_prefix {
    my ($self, $prefix) = @_;
    return 1 if defined $prefix && $prefix eq '';
    return 0 unless defined $prefix && $prefix =~ /\A[a-z]+\z/;
    my $group = $self->{root};
    for my $letter (split //, $prefix) {
        my $at = $self->step($group, $letter);
        return 0 unless $at;
        $group = $self->child($self->rec($at));
    }
    return 1;
}

# The path a walk takes, as record indices, for a word the automaton
# accepts. Used to check the plan's hand-worked walks cell by cell.
sub trace {
    my ($self, $word) = @_;
    my @path;
    my $group = $self->{root};
    for my $letter (split //, $word) {
        my $at = $self->step($group, $letter);
        return undef unless $at;
        push @path, $at;
        $group = $self->child($self->rec($at));
    }
    return \@path;
}

1;

__END__

=head1 NAME

FRDTest::Reference - the artifact format walked in pure Perl

=head1 DESCRIPTION

A slow, whole-file reader of a File::Raw::DAWG artifact, written from
the bit layout in F<include/file_raw_dawg.h> alone. It lets the format
be exercised before the XS exists and gives the XS reader something
independent to be compared against afterwards. Test code only.

=cut
