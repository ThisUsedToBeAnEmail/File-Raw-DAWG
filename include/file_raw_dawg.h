/*
 * file_raw_dawg.h - the on-disk format of a File::Raw::DAWG artifact.
 *
 * THIS FILE IS THE NORMATIVE COPY OF THE FORMAT. Every offset and every
 * bit width used by the builder, the reader, the tests and any consumer
 * comes from here; nothing restates a number of its own.
 *
 * The walk itself (frd_open, frd_step, frd_contains and the FRD_E_*
 * codes) is added by plan_file_raw_dawg/04-the-abi.md. This file at
 * phase 01 is the numbers alone, so that the builder and the reader can
 * be written against it independently and still meet.
 *
 * No Perl. Not EXTERN.h, not perl.h, not ppport.h: a consumer that wants
 * to croak on a bad artifact does so in its own XS.
 *
 * C89. No declarations after statements, no //, no long long.
 *
 *
 * THE LAYOUT
 *
 *   offset  size  what
 *   0       8     magic, the bytes "FRDAWG1\n"
 *   8       4     format version, 1
 *   12      4     node_count, the number of records that follow
 *   16      4     word_count, the number of words accepted
 *   20      4     root, the record index of the start state's first
 *                 transition
 *   24      4     flags, 0 in format 1
 *   28      4     reserved, 0 in format 1
 *   32      32    the SHA-256 of the source list, as bytes
 *   64      4n    the records
 *
 * Every integer is unsigned and little-endian on every platform, and is
 * read byte by byte: a record is not guaranteed to be aligned for a
 * wider load once the header changes, and a cast would be wrong on a big
 * endian host as well. File size is exactly FRD_HEADER_LEN +
 * FRD_REC_LEN * node_count and a reader refuses anything else.
 *
 * The trailing newline in the magic is deliberate. A transfer that
 * rewrites line endings turns "FRDAWG1\n" into "FRDAWG1\r\n", which
 * fails the magic loudly instead of shifting every record by one byte.
 *
 *
 * THE RECORD
 *
 * One 32 bit word per transition, not per state:
 *
 *   bits    width  what
 *   0-4     5      the letter, 'a' = 1 through 'z' = 26. 0 is never a
 *                  letter
 *   5       1      terminal: the state this transition arrives at ends a
 *                  word
 *   6       1      last: the final transition of its state's group
 *   7-31    25     child: the record index of the first transition of
 *                  the state this transition arrives at, or 0 for a
 *                  state with no transitions
 *
 * A state is a contiguous ascending run of records ending at the one
 * with the last bit set, so there are no pointers in the file at all: a
 * state is an index, a child lookup is a short scan, and two states with
 * identical runs are literally the same run.
 *
 * RECORD 0 IS A SENTINEL AND IS ALL ZERO BITS. It is what child means
 * when a state has no transitions, so no real state may begin at index
 * 0, and a reader refuses an artifact whose record 0 is not zero.
 *
 * The letters within a group ascend. Nothing reads them in order; a
 * fixed order is what makes a build reproducible.
 */

#ifndef FILE_RAW_DAWG_H
#define FILE_RAW_DAWG_H

/*
 * A 32 bit unsigned type, without stdint.h, which C89 does not have.
 * unsigned int is 32 bits everywhere this distribution will ever run;
 * the fallback is for the platforms where it is not. A wider type is
 * harmless: every value here is below 2^32 and every value written to
 * the artifact is written as four explicit bytes.
 *
 * Defined once and guarded. A C89 compiler treats a repeated typedef as
 * an error, not a note, so nothing else in this distribution may spell
 * it out again.
 */
#ifndef FRD_U32_DEFINED
#define FRD_U32_DEFINED
#include <limits.h>
#if UINT_MAX >= 4294967295U
typedef unsigned int frd_u32;
#else
typedef unsigned long frd_u32;
#endif
#endif

/* The header. */
#define FRD_MAGIC          "FRDAWG1\n"
#define FRD_MAGIC_LEN      8
#define FRD_FORMAT         1

#define FRD_OFF_MAGIC      0
#define FRD_OFF_FORMAT     8
#define FRD_OFF_NODES      12
#define FRD_OFF_WORDS      16
#define FRD_OFF_ROOT       20
#define FRD_OFF_FLAGS      24
#define FRD_OFF_RESERVED   28
#define FRD_OFF_DIGEST     32
#define FRD_DIGEST_LEN     32
#define FRD_HEADER_LEN     64

/* The records. */
#define FRD_REC_LEN        4
#define FRD_LETTER_MASK    0x1FU
#define FRD_TERMINAL_BIT   0x20U
#define FRD_LAST_BIT       0x40U
#define FRD_CHILD_SHIFT    7

/*
 * 25 bits of child index. A build that would exceed this dies naming the
 * word it was on; the escape is a format version, never a silent wrap.
 * ENABLE minimises to well under a fifth of a million.
 */
#define FRD_MAX_NODES      0x1FFFFFFU

/* The alphabet. 0 is the sentinel's letter; 27 to 31 are refused. */
#define FRD_MIN_LETTER     1
#define FRD_MAX_LETTER     26

/*
 * Flags. Format 1 writes none and refuses any it does not understand, so
 * an old reader can never half-read a new artifact. Bit 0 is spoken for:
 * a counted automaton, each record also carrying the number of words
 * below it, which makes the structure a perfect hash.
 */
#define FRD_FLAG_COUNTED   0x1U
#define FRD_FLAGS_KNOWN    0U

/*
 * A mapped or slurped artifact, and what validating it decided. The
 * caller owns the bytes and must keep them alive for the life of this
 * struct: nothing here copies and nothing here frees.
 */
typedef struct {
    const unsigned char *base;   /* the artifact, from byte 0 */
    size_t               len;    /* its full length            */
    frd_u32              nodes;
    frd_u32              words;
    frd_u32              root;
} frd_dawg;

/*
 * THE ARTIFACT IS UNTRUSTED INPUT. It is a file on disk that a user can
 * truncate, edit or replace, and a walk over it is a loop of "follow
 * this index", so an index that is not checked is a read at an
 * arbitrary offset. Every one of these is a refusal a caller can act
 * on, and every one of them has its own code because a reader that says
 * only "bad file" makes a bad deploy unreadable.
 */
#define FRD_E_SHORT    (-1)  /* shorter than the header                     */
#define FRD_E_CRLF     (-2)  /* the magic but for its last byte: see below  */
#define FRD_E_MAGIC    (-3)  /* not this format at all                      */
#define FRD_E_VERSION  (-4)  /* a format version this reader does not know  */
#define FRD_E_FLAGS    (-5)  /* a flag this reader does not know            */
#define FRD_E_RAGGED   (-6)  /* not a whole number of records: truncated    */
#define FRD_E_LENGTH   (-7)  /* node_count disagrees: a rewritten header    */
#define FRD_E_SENTINEL (-8)  /* record 0 is not all zero bits               */
#define FRD_E_ROOT     (-9)  /* the root is not a record                    */
#define FRD_E_BOUNDS  (-10)  /* a walk left the records: a corrupt artifact */

/*
 * FRD_E_CRLF is the whole reason the magic ends in a newline. A
 * transfer that rewrites line endings is the one corruption that would
 * otherwise shift every record by a byte and still look plausible, so
 * when the magic matches but for that final byte, the reader says which
 * thing happened rather than "bad magic".
 */

/*
 * THE WALK.
 *
 * Header only: no allocation, no I/O, no Perl, nothing to link against.
 * A consumer maps or reads the artifact its own way, calls frd_open on
 * the bytes, and walks. This distribution's own XS does exactly that,
 * which is the only thing that keeps this header honest: if it drifted,
 * these tests would fail before any consumer's did.
 *
 * `static` alone would make every translation unit that includes this
 * header for its constants warn about functions it does not call, so
 * FRD_INLINE is the compiler's inline spelling wherever there is one.
 * A compiler with none gets plain `static` and may warn; that is the
 * only cost and it is a warning, not an error.
 */
#ifndef FRD_INLINE
#  if defined(__GNUC__)
#    define FRD_INLINE static __inline__
#  elif defined(_MSC_VER)
#    define FRD_INLINE static __inline
#  elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 199901L
#    define FRD_INLINE static inline
#  else
#    define FRD_INLINE static
#  endif
#endif

#include <stddef.h>
#include <string.h>

/*
 * Four bytes, little-endian, wherever they are. See the note on the
 * layout above: nothing is guaranteed to be aligned for a wider load,
 * and a cast would be wrong on a big endian host as well. A compiler
 * that knows better folds this back into one load.
 */
FRD_INLINE frd_u32 frd_u32_at(const unsigned char *p)
{
    return  (frd_u32) p[0]
         | ((frd_u32) p[1] <<  8)
         | ((frd_u32) p[2] << 16)
         | ((frd_u32) p[3] << 24);
}

/* One record. The caller must already have bounds-checked i. */
FRD_INLINE frd_u32 frd_rec(const frd_dawg *d, frd_u32 i)
{
    return frd_u32_at(d->base + FRD_HEADER_LEN + (size_t) i * FRD_REC_LEN);
}

FRD_INLINE int     frd_letter(frd_u32 rec)   { return (int) (rec & FRD_LETTER_MASK); }
FRD_INLINE int     frd_is_terminal(frd_u32 rec) { return (rec & FRD_TERMINAL_BIT) ? 1 : 0; }
FRD_INLINE int     frd_is_last(frd_u32 rec)  { return (rec & FRD_LAST_BIT) ? 1 : 0; }
FRD_INLINE frd_u32 frd_child(frd_u32 rec)    { return rec >> FRD_CHILD_SHIFT; }

/*
 * Validate a whole artifact and fill in `out`. 0, or a negative
 * FRD_E_*. The caller owns the bytes and must keep them alive for as
 * long as it uses `out`: nothing here copies and nothing here frees.
 */
FRD_INLINE int frd_open(const unsigned char *base, size_t len, frd_dawg *out)
{
    frd_u32 format, nodes, words, root, flags, reserved;
    size_t records;

    if (len < (size_t) FRD_HEADER_LEN) return FRD_E_SHORT;

    if (memcmp(base + FRD_OFF_MAGIC, FRD_MAGIC, FRD_MAGIC_LEN) != 0) {
        /* The newline in the magic earns its keep here. */
        if (memcmp(base + FRD_OFF_MAGIC, FRD_MAGIC, FRD_MAGIC_LEN - 1) == 0) {
            return FRD_E_CRLF;
        }
        return FRD_E_MAGIC;
    }

    out->base = base;
    out->len  = len;

    format   = frd_u32_at(base + FRD_OFF_FORMAT);
    nodes    = frd_u32_at(base + FRD_OFF_NODES);
    words    = frd_u32_at(base + FRD_OFF_WORDS);
    root     = frd_u32_at(base + FRD_OFF_ROOT);
    flags    = frd_u32_at(base + FRD_OFF_FLAGS);
    reserved = frd_u32_at(base + FRD_OFF_RESERVED);

    if (format != FRD_FORMAT) return FRD_E_VERSION;
    if (flags != FRD_FLAGS_KNOWN || reserved != 0) return FRD_E_FLAGS;

    if ((len - FRD_HEADER_LEN) % FRD_REC_LEN) return FRD_E_RAGGED;
    records = (len - FRD_HEADER_LEN) / FRD_REC_LEN;
    if ((size_t) nodes != records || nodes == 0) return FRD_E_LENGTH;

    out->nodes = nodes;
    out->words = words;
    out->root  = root;

    if (frd_rec(out, 0) != 0) return FRD_E_SENTINEL;

    /* An empty automaton is the sentinel alone and its root is 0. */
    if (nodes == 1) {
        if (root != 0) return FRD_E_ROOT;
    }
    else if (root < 1 || root >= nodes) {
        return FRD_E_ROOT;
    }

    return 0;
}

/*
 * The record in the group beginning at `group` carrying `letter`.
 * 0 and *out set, 1 for no such letter, or FRD_E_BOUNDS.
 *
 * Group 0 is the empty state and is a real answer: nothing follows it,
 * so no letter is there. A group past the end is not an answer, it is a
 * handle from somewhere else or a corrupt artifact, and saying "no such
 * letter" to it would turn caller error into a silently wrong lookup.
 *
 * The scan is bounded by node_count as well as by the last bit, because
 * `last` is one bit in a file anyone can edit.
 */
FRD_INLINE int frd_step(const frd_dawg *d, frd_u32 group, int letter, frd_u32 *out)
{
    frd_u32 i;

    if (group == 0) return 1;
    if (group >= d->nodes) return FRD_E_BOUNDS;
    if (letter < FRD_MIN_LETTER || letter > FRD_MAX_LETTER) return 1;

    for (i = group; i < d->nodes; i++) {
        frd_u32 v = frd_rec(d, i);
        if (frd_letter(v) == letter) {
            *out = i;
            return 0;
        }
        if (frd_is_last(v)) return 1;
    }
    return FRD_E_BOUNDS;
}

/* 1, 0, or FRD_E_BOUNDS. */
FRD_INLINE int frd_terminal(const frd_dawg *d, frd_u32 at)
{
    if (at == 0 || at >= d->nodes) return FRD_E_BOUNDS;
    return frd_is_terminal(frd_rec(d, at));
}

/* The group the transition arrives at, 0 for none, or FRD_E_BOUNDS. */
FRD_INLINE int frd_next(const frd_dawg *d, frd_u32 at, frd_u32 *out)
{
    frd_u32 child;
    if (at == 0 || at >= d->nodes) return FRD_E_BOUNDS;
    child = frd_child(frd_rec(d, at));
    if (child >= d->nodes) return FRD_E_BOUNDS;
    *out = child;
    return 0;
}

/*
 * 1 accepted, 0 refused, FRD_E_BOUNDS for a corrupt artifact. A letter
 * outside a to z is refused, never an error: asking whether "Cat" is in
 * the list is a fair question with a plain answer.
 */
FRD_INLINE int frd_contains(const frd_dawg *d, const unsigned char *w, size_t n)
{
    frd_u32 group, at;
    size_t i;

    if (n == 0) return 0;
    group = d->root;

    for (i = 0; i < n; i++) {
        int letter = (int) w[i] - 'a' + 1;
        int rc;
        if (letter < FRD_MIN_LETTER || letter > FRD_MAX_LETTER) return 0;

        rc = frd_step(d, group, letter, &at);
        if (rc == 1) return 0;
        if (rc < 0) return rc;

        if (i + 1 == n) return frd_is_terminal(frd_rec(d, at));

        rc = frd_next(d, at, &group);
        if (rc < 0) return rc;
        if (group == 0) return 0;
    }
    return 0;
}

/* 1 if anything in the automaton begins with w, w itself included. */
FRD_INLINE int frd_has_prefix(const frd_dawg *d, const unsigned char *w, size_t n)
{
    frd_u32 group, at;
    size_t i;

    if (n == 0) return 1;
    group = d->root;

    for (i = 0; i < n; i++) {
        int letter = (int) w[i] - 'a' + 1;
        int rc;
        if (letter < FRD_MIN_LETTER || letter > FRD_MAX_LETTER) return 0;

        rc = frd_step(d, group, letter, &at);
        if (rc == 1) return 0;
        if (rc < 0) return rc;

        if (i + 1 == n) return 1;

        rc = frd_next(d, at, &group);
        if (rc < 0) return rc;
        if (group == 0) return 0;
    }
    return 0;
}

/* A short English phrase for a code. Never NULL. */
FRD_INLINE const char *frd_strerror(int code)
{
    switch (code) {
        case 0:              return "no error";
        case FRD_E_SHORT:    return "shorter than a header";
        case FRD_E_CRLF:     return "line endings rewritten in transit";
        case FRD_E_MAGIC:    return "not a File::Raw::DAWG artifact";
        case FRD_E_VERSION:  return "a format version this reader does not know";
        case FRD_E_FLAGS:    return "a flag this reader does not know";
        case FRD_E_RAGGED:   return "not a whole number of records";
        case FRD_E_LENGTH:   return "node_count disagrees with the length";
        case FRD_E_SENTINEL: return "record 0 is not the sentinel";
        case FRD_E_ROOT:     return "the root is not a record";
        case FRD_E_BOUNDS:   return "a walk left the records: the artifact is corrupt";
        default:             return "unknown error";
    }
}

#endif /* FILE_RAW_DAWG_H */
