package File::Raw::DAWG;

use 5.008003;
use strict;
use warnings;

use Digest::SHA ();
use File::Raw ();

require XSLoader;

our $VERSION = '0.01';

XSLoader::load('File::Raw::DAWG', $VERSION);

# The one FRD_B_* code the Perl side has to tell apart from the others,
# because an order complaint has to name both words to be readable. A
# lexical rather than a constant sub: it is nobody's interface, and a
# named sub here is a naked subroutine as far as the pod coverage test
# is concerned.
my $B_ORDER = -1;

sub open {
    my ($class, $path, $opts) = @_;
    $opts ||= {};

    die "File::Raw::DAWG->open: no artifact path named\n" unless defined $path;
    die "File::Raw::DAWG->open: cannot read $path\n" unless -f $path;

    my $want_mmap = exists $opts->{mmap} ? $opts->{mmap} : 1;

    my $self = bless { path => $path, mapped => 0 }, $class;

    if ($want_mmap) {
        my $mmap = eval { File::Raw::mmap_open($path) };
        if ($mmap) {
            $self->{mmap}  = $mmap;
            $self->{mapped} = 1;
        }
    }
    if (!$self->{mmap}) {
        CORE::open my $fh, '<', $path
            or die "File::Raw::DAWG->open: cannot read $path: $!\n";
        binmode $fh;
        my $bytes = do { local $/; <$fh> };
        close $fh;
        $self->{bytes} = defined $bytes ? $bytes : '';
    }

    my ($rc, $nodes, $words, $root) = _open_check($self->_buf);
    die "File::Raw::DAWG->open: $path: " . _strerror($rc) . "\n" if $rc != 0;

    @{$self}{qw(nodes words root)} = ($nodes, $words, $root);
    return $self;
}

# THE ONE RULE OF THIS FILE.
#
# With a mapping, File::Raw's data() hands back a scalar whose PV points
# straight at the mapped bytes: no copy, and the kernel shares those
# pages with every other process that maps the same file. Binding it to
# a scalar undoes all of that. `my $b = $m->data` copies the entire
# mapping into the heap, once per assignment, which on a 64 MB file is
# 64 MB of resident size that nobody asked for and nobody shares.
#
# So this returns it and nothing holds it. Every caller passes it
# straight into an XSUB as an argument, where it is read and forgotten.
# NEVER assign the result of _buf to anything.
sub _buf {
    my ($self) = @_;
    return $self->{mmap} ? $self->{mmap}->data : $self->{bytes};
}

sub contains   { my ($s, $w) = @_; return defined $w ? _contains($s->_buf, $w) : 0 }
sub has_prefix { my ($s, $w) = @_; return defined $w ? _has_prefix($s->_buf, $w) : 0 }

sub node_count { return $_[0]{nodes} }
sub word_count { return $_[0]{words} }
sub root       { return $_[0]{root} }
sub path       { return $_[0]{path} }
sub mapped     { return $_[0]{mapped} }

sub list_digest {
    my ($self) = @_;
    return $self->{digest} if defined $self->{digest};
    $self->{digest} = unpack 'H*', substr $self->_buf, 32, 32;
    return $self->{digest};
}

# A handle is a plain integer, not an object: a solver recurses sixteen
# deep and unwinds a hundred thousand times, and an integer costs
# nothing to make and nothing to collect.
#
# There are two kinds of handle and they are not interchangeable. A
# STATE is where a group of transitions begins, and `root`, `children`,
# `child` and `step` take one. A TRANSITION is one record inside such a
# group, and `is_terminal` and `next_node` take one. `child` turns a
# state into a transition; `next_node` turns a transition back into a
# state.
sub child      { my ($s, $g, $l) = @_; return _child($s->_buf, $g, $l) }
sub is_terminal { my ($s, $at) = @_; return _is_terminal($s->_buf, $at) }
sub next_node  { my ($s, $at) = @_; return _next_node($s->_buf, $at) }
sub children   { my ($s, $g) = @_; return _children($s->_buf, $g) }

# One edge in one call: ($next_state, $terminal), or the empty list.
sub step { my ($s, $g, $l) = @_; return _step($s->_buf, $g, $l) }

sub build {
    my ($class, $in, $out, $opts) = @_;
    $opts ||= {};

    die "File::Raw::DAWG->build: no input list named\n"  unless defined $in;
    die "File::Raw::DAWG->build: no artifact path named\n" unless defined $out;
    die "File::Raw::DAWG->build: cannot read $in\n" unless -f $in;

    my $handle = _builder_new();
    my ($words, $nodes, $root, $records);

    my $line = 0;
    my $prev;
    my $err;
    my $ok = eval {
        # The list is streamed, never slurped: the register is bounded by
        # the automaton and the reader should be too.
        File::Raw::each_line($in, sub {
            return if $err;
            $line++;
            my $word = $_;

            # each_line strips the newline and nothing else, so a list
            # written with CRLF arrives with its carriage return still
            # attached and is refused here by name rather than becoming
            # a word nobody can spell.
            if ($word =~ /\r\z/) {
                $err = "line $line has a carriage return: the list has CRLF line endings";
                return;
            }
            if ($word !~ /\A[a-z]+\z/) {
                $err = "line $line is not a word of a to z: '" . _show($word) . "'";
                return;
            }

            my $rc = _builder_add($handle, $word);
            if ($rc != 0) {
                $err = "line $line ('" . _show($word) . "'): " . _builder_strerror($rc);
                # An order complaint is unreadable without both words.
                $err .= ", the word before was '$prev'"
                    if $rc == $B_ORDER && defined $prev;
                return;
            }
            $prev = $word;
        });

        die "$err\n" if $err;

        my $rc = _builder_finish($handle);
        die 'File::Raw::DAWG->build: ' . _builder_strerror($rc) . "\n" if $rc != 0;

        ($records, $nodes, $words, $root) = _builder_result($handle);
        1;
    };
    my $died = $@;
    _builder_free($handle);
    die $died || "File::Raw::DAWG->build: failed for a reason it did not say\n"
        unless $ok;

    my $digest = Digest::SHA->new(256);
    $digest->addfile($in, 'b');

    my $bytes = _magic()
              . pack('V', _format())
              . pack('V', $nodes)
              . pack('V', $words)
              . pack('V', $root)
              . pack('V', 0)
              . pack('V', 0)
              . $digest->digest
              . $records;

    _spew($out, $bytes);

    return {
        words  => $words,
        nodes  => $nodes,
        bytes  => length $bytes,
        digest => unpack('H*', substr $bytes, 32, 32),
    };
}

# Written beside the target and renamed, so a build that dies half way
# leaves no artifact that looks finished.
sub _spew {
    my ($path, $bytes) = @_;
    my $tmp = "$path.$$.tmp";
    # CORE:: throughout this file: `sub open` above shadows the builtin
    # inside this package, and a bare open here is an ambiguity warning
    # at best and the wrong call at worst.
    CORE::open my $fh, '>', $tmp
        or die "File::Raw::DAWG->build: cannot write $tmp: $!\n";
    binmode $fh;
    print {$fh} $bytes or die "File::Raw::DAWG->build: cannot write $tmp: $!\n";
    close $fh or die "File::Raw::DAWG->build: cannot close $tmp: $!\n";
    if (!rename $tmp, $path) {
        my $why = $!;
        unlink $tmp;
        die "File::Raw::DAWG->build: cannot rename $tmp to $path: $why\n";
    }
    return 1;
}

sub _show {
    my ($word) = @_;
    $word = substr($word, 0, 40) . '...' if length $word > 40;
    $word =~ s/([^\x20-\x7e])/sprintf '\\x%02x', ord $1/ge;
    return $word;
}

1;

__END__

=head1 NAME

File::Raw::DAWG - a word list as one packed file, walked in place

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

    use File::Raw::DAWG;

    my $built = File::Raw::DAWG->build('words.txt', 'words.dawg');
    # { words => 172819, nodes => 148002, bytes => 592072, digest => '...' }

=head1 DESCRIPTION

Compiles a sorted word list into a minimal acyclic automaton, writes it
as one packed artifact, and answers membership, prefix and child-walk
questions over that artifact mapped read-only. A hundred and seventy
thousand words cost a couple of megabytes in a process rather than the
tens of megabytes the same list costs as a hash, and forked workers
share one copy.

The artifact's layout is specified in F<include/file_raw_dawg.h>, which
is the normative copy of every offset and bit width in the format and is
installed for other distributions to build against.

=head1 METHODS

=head2 build

    my $built = File::Raw::DAWG->build($list_path, $artifact_path);

Reads the list and writes the artifact, returning a hashref of
C<words>, C<nodes>, C<bytes> and C<digest>. C<digest> is the lowercase
hex SHA-256 of the list file, which is also recorded in the artifact so
that a consumer can prove the artifact in its tree was built from the
list in its tree.

The list must be one word a line, one to sixty-four letters of C<a> to
C<z>, sorted ascending and unique. A shorter floor than that is the
caller's rule and not this one: a lexicon that wants no word under three
letters filters its list before building. It is checked rather than sorted:
sorting inside would hide a caller feeding an unsorted list and would
need the whole list in memory, which is the thing the streaming avoids.
A bad line dies naming its line number and what was wrong with it, and
no artifact is written.

=head2 open

    my $d = File::Raw::DAWG->open($artifact_path);
    my $d = File::Raw::DAWG->open($artifact_path, { mmap => 0 });

Opens an artifact and validates its header, dying with what was wrong
if it is not one. Maps the file by default so that forked workers share
one copy of it; C<mmap =E<gt> 0> reads it into memory instead, and
C<mapped> says which happened.

=head2 contains

    $d->contains('quixotic');

True when the word is in the list. A word outside C<a> to C<z> is false
rather than an error: asking whether C<Cat> is in the list is a fair
question with a plain answer.

=head2 has_prefix

    $d->has_prefix('quix');

True when anything in the list begins with it, the prefix itself
included. The empty prefix is true.

=head2 node_count

How many records the artifact holds, the sentinel included.

=head2 word_count

How many words the automaton accepts.

=head2 path

The path this reader was opened from.

=head2 mapped

True when the artifact is mapped, false when it was read into memory.

=head2 list_digest

The lowercase hex SHA-256 of the list the artifact was built from, as
recorded in the artifact when it was built.

=head2 root

The state the walk starts at.

A handle is a plain integer, because a solver recurses and unwinds
hundreds of thousands of times and an integer costs nothing to make and
nothing to collect.

There are two kinds of handle and they are not interchangeable. A
B<state> is where a group of transitions begins; C<root>, C<children>,
C<child> and C<step> take one. A B<transition> is one record inside
such a group; C<is_terminal> and C<next_node> take one. C<child> turns
a state into a transition, and C<next_node> turns a transition back
into a state.

    my $state = $d->root;
    my $at    = $d->child($state, 'c') or return;   # a transition
    $d->is_terminal($at);                           # does 'c' end a word
    $state    = $d->next_node($at) or return;       # a state again
    for my $e (@{ $d->children($state) }) { ... }   # [ letter, at, terminal ]

A handle that is not a record of this artifact is refused, loudly. It
is caller error, and the alternative is a lookup that quietly answers
about the wrong thing.

=head2 child

    my $at = $d->child($state, 'c');

The transition in that state carrying that letter, or undef.

=head2 next_node

    my $state = $d->next_node($at);

The state that transition arrives at, or undef when it arrives at the
empty state.

=head2 is_terminal

    $d->is_terminal($at);

True when a word ends at that transition.

=head2 children

    for my $e (@{ $d->children($state) }) { ... }

Every transition of that state, as C<[ letter, transition, terminal ]>.

=head2 step

    my ($next, $ends) = $d->step($state, 'a') or return;

A whole edge in one call: the state reached and whether a word ends
there, or the empty list when the state has no such letter. It exists
because an XSUB call per edge is the only cost this design cannot
remove, so an edge should not cost three of them.

=head1 THE C HEADER

F<file_raw_dawg.h> is public, installed, and the normative copy of the
format: every offset, every bit width, every C<FRD_E_> code and the
whole walk. It is header only, C89, and has no Perl in it, so a C
program can map an artifact its own way and walk it without this
module:

    #include "file_raw_dawg.h"

    frd_dawg d;
    int rc = frd_open(bytes, len, &d);
    if (rc != 0) { fprintf(stderr, "%s\n", frd_strerror(rc)); return 1; }
    if (frd_contains(&d, (const unsigned char *) "quixotic", 8) == 1) { ... }

To build against it from another distribution, depend on this one
through L<ExtUtils::Depends>:

    my $pkg = ExtUtils::Depends->new('Your::Module', 'File::Raw::DAWG');

This distribution's own XS uses the header rather than keeping a second
copy of the bit layout, which is the only thing that keeps it honest: a
header that drifted would fail these tests before it failed anyone
else's.

The compatibility unit is the format version in the artifact, not this
module's version. Format 1 is what this reader accepts and what this
builder writes, and a reader refuses a version or a flag it does not
know rather than half-reading it.

=head1 STATUS

C<build>, C<open>, the walk and the installed C header are here. The
portability matrix and the gate are
F<plan_file_raw_dawg/> phases 05 and 07.

=head1 AUTHOR

LNATION, C<< <email at lnation.org> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by LNATION.

This is free software, licensed under the Artistic License 2.0.

=cut
