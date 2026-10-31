#define PERL_NO_GET_CONTEXT

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "dawg_build.h"

/*
 * The thin half. Everything here does one thing: move bytes between
 * Perl and dawg_build.c, and turn a FRD_B_* code into a croak. The
 * algorithm is in the C and the streaming, the digest and the file
 * writing are in the Perl, because each of the three belongs where it
 * is cheapest to get right.
 *
 * The builder handle is an IV, not an object: it is private (every XSUB
 * here is underscore-prefixed), File::Raw::DAWG::build owns it from
 * beginning to end inside an eval, and a blessed wrapper would mean a
 * second package in this file, which this house does not do.
 */

MODULE = File::Raw::DAWG        PACKAGE = File::Raw::DAWG

PROTOTYPES: DISABLE

IV
_builder_new()
    CODE:
        {
            frd_builder *b = frd_builder_new();
            if (!b) croak("File::Raw::DAWG: out of memory starting a build");
            RETVAL = PTR2IV(b);
        }
    OUTPUT:
        RETVAL

int
_builder_add(handle, word)
        IV handle
        SV *word
    CODE:
        {
            STRLEN len;
            const char *p = SvPV_const(word, len);
            RETVAL = frd_builder_add(INT2PTR(frd_builder *, handle),
                                     (const unsigned char *) p, (size_t) len);
        }
    OUTPUT:
        RETVAL

int
_builder_finish(handle)
        IV handle
    CODE:
        RETVAL = frd_builder_finish(INT2PTR(frd_builder *, handle));
    OUTPUT:
        RETVAL

void
_builder_result(handle)
        IV handle
    PPCODE:
        {
            frd_builder *b = INT2PTR(frd_builder *, handle);
            const void *rec = frd_builder_records(b);
            frd_u32 nodes = frd_builder_node_count(b);
            if (!rec) croak("File::Raw::DAWG: the build is not finished");
            EXTEND(SP, 4);
            PUSHs(sv_2mortal(newSVpvn((const char *) rec,
                                      (STRLEN) nodes * FRD_REC_LEN)));
            PUSHs(sv_2mortal(newSVuv((UV) nodes)));
            PUSHs(sv_2mortal(newSVuv((UV) frd_builder_word_count(b))));
            PUSHs(sv_2mortal(newSVuv((UV) frd_builder_root(b))));
        }

void
_builder_free(handle)
        IV handle
    CODE:
        frd_builder_free(INT2PTR(frd_builder *, handle));

const char *
_builder_strerror(code)
        int code
    CODE:
        RETVAL = frd_builder_strerror(code);
    OUTPUT:
        RETVAL

UV
_header_len()
    CODE:
        RETVAL = (UV) FRD_HEADER_LEN;
    OUTPUT:
        RETVAL

UV
_format()
    CODE:
        RETVAL = (UV) FRD_FORMAT;
    OUTPUT:
        RETVAL

SV *
_magic()
    CODE:
        RETVAL = newSVpvn(FRD_MAGIC, FRD_MAGIC_LEN);
    OUTPUT:
        RETVAL

#
# The reader.
#
# Every one of these takes the artifact as an SV and re-derives the
# header from it. THE SV IS NEVER COPIED AND MUST NEVER BE ASSIGNED TO A
# SCALAR ON THE PERL SIDE: File::Raw's mmap data() hands back a scalar
# whose PV points straight at the mapping, and `my $x = $m->data` copies
# the whole mapping into the heap. File::Raw::DAWG::_buf returns it
# without binding it, and the comment there says why.
#
# Re-validating per call is four byte loads and a handful of compares,
# and it buys the guarantee that a reader can never hold a node count
# that disagrees with the bytes it is reading.
#

void
_open_check(data)
        SV *data
    PPCODE:
        {
            STRLEN len;
            const char *p = SvPV_const(data, len);
            frd_dawg d;
            int rc = frd_open((const unsigned char *) p, (size_t) len, &d);
            EXTEND(SP, 4);
            PUSHs(sv_2mortal(newSViv((IV) rc)));
            PUSHs(sv_2mortal(newSVuv((UV) (rc == 0 ? d.nodes : 0))));
            PUSHs(sv_2mortal(newSVuv((UV) (rc == 0 ? d.words : 0))));
            PUSHs(sv_2mortal(newSVuv((UV) (rc == 0 ? d.root  : 0))));
        }

const char *
_strerror(code)
        int code
    CODE:
        RETVAL = frd_strerror(code);
    OUTPUT:
        RETVAL

int
_contains(data, word)
        SV *data
        SV *word
    CODE:
        {
            STRLEN len, wlen;
            const char *p = SvPV_const(data, len);
            const char *w = SvPV_const(word, wlen);
            frd_dawg d;
            int rc = frd_open((const unsigned char *) p, (size_t) len, &d);
            if (rc != 0) croak("File::Raw::DAWG: %s", frd_strerror(rc));
            rc = frd_contains(&d, (const unsigned char *) w, (size_t) wlen);
            if (rc < 0) croak("File::Raw::DAWG: %s", frd_strerror(rc));
            RETVAL = rc;
        }
    OUTPUT:
        RETVAL

int
_has_prefix(data, word)
        SV *data
        SV *word
    CODE:
        {
            STRLEN len, wlen;
            const char *p = SvPV_const(data, len);
            const char *w = SvPV_const(word, wlen);
            frd_dawg d;
            int rc = frd_open((const unsigned char *) p, (size_t) len, &d);
            if (rc != 0) croak("File::Raw::DAWG: %s", frd_strerror(rc));
            rc = frd_has_prefix(&d, (const unsigned char *) w, (size_t) wlen);
            if (rc < 0) croak("File::Raw::DAWG: %s", frd_strerror(rc));
            RETVAL = rc;
        }
    OUTPUT:
        RETVAL

# The transition in the state at `group` carrying `letter`, or nothing.
void
_child(data, group, letter)
        SV *data
        UV group
        SV *letter
    PPCODE:
        {
            STRLEN len, llen;
            const char *p = SvPV_const(data, len);
            const char *l = SvPV_const(letter, llen);
            frd_dawg d;
            frd_u32 at = 0;
            int rc = frd_open((const unsigned char *) p, (size_t) len, &d);
            if (rc != 0) croak("File::Raw::DAWG: %s", frd_strerror(rc));
            if (llen != 1) XSRETURN_EMPTY;
            rc = frd_step(&d, (frd_u32) group, (int) l[0] - 'a' + 1, &at);
            if (rc < 0) croak("File::Raw::DAWG: %s", frd_strerror(rc));
            if (rc == 1) XSRETURN_EMPTY;
            XSRETURN_UV((UV) at);
        }

int
_is_terminal(data, at)
        SV *data
        UV at
    CODE:
        {
            STRLEN len;
            const char *p = SvPV_const(data, len);
            frd_dawg d;
            int rc = frd_open((const unsigned char *) p, (size_t) len, &d);
            if (rc != 0) croak("File::Raw::DAWG: %s", frd_strerror(rc));
            rc = frd_terminal(&d, (frd_u32) at);
            if (rc < 0) croak("File::Raw::DAWG: %s", frd_strerror(rc));
            RETVAL = rc;
        }
    OUTPUT:
        RETVAL

# The state the transition at `at` arrives at, or nothing when it
# arrives at the empty state.
void
_next_node(data, at)
        SV *data
        UV at
    PPCODE:
        {
            STRLEN len;
            const char *p = SvPV_const(data, len);
            frd_dawg d;
            frd_u32 group = 0;
            int rc = frd_open((const unsigned char *) p, (size_t) len, &d);
            if (rc != 0) croak("File::Raw::DAWG: %s", frd_strerror(rc));
            rc = frd_next(&d, (frd_u32) at, &group);
            if (rc < 0) croak("File::Raw::DAWG: %s", frd_strerror(rc));
            if (group == 0) XSRETURN_EMPTY;
            XSRETURN_UV((UV) group);
        }

# One edge in one call: the state reached and whether the word ends
# there. This is the call a solver's inner loop makes, and the reason it
# exists is that an XSUB call per edge is the only cost this design
# cannot remove, so an edge should not cost three of them.
void
_step(data, group, letter)
        SV *data
        UV group
        SV *letter
    PPCODE:
        {
            STRLEN len, llen;
            const char *p = SvPV_const(data, len);
            const char *l = SvPV_const(letter, llen);
            frd_dawg d;
            frd_u32 at = 0, next = 0;
            int rc = frd_open((const unsigned char *) p, (size_t) len, &d);
            if (rc != 0) croak("File::Raw::DAWG: %s", frd_strerror(rc));
            if (llen != 1) XSRETURN_EMPTY;
            rc = frd_step(&d, (frd_u32) group, (int) l[0] - 'a' + 1, &at);
            if (rc < 0) croak("File::Raw::DAWG: %s", frd_strerror(rc));
            if (rc == 1) XSRETURN_EMPTY;
            rc = frd_next(&d, at, &next);
            if (rc < 0) croak("File::Raw::DAWG: %s", frd_strerror(rc));
            EXTEND(SP, 2);
            PUSHs(sv_2mortal(newSVuv((UV) next)));
            PUSHs(sv_2mortal(newSViv((IV) ((frd_rec(&d, at) & FRD_TERMINAL_BIT) ? 1 : 0))));
        }

# [ [ letter, transition, terminal ], ... ] for the state at `group`.
void
_children(data, group)
        SV *data
        UV group
    PPCODE:
        {
            STRLEN len;
            const char *p = SvPV_const(data, len);
            frd_dawg d;
            frd_u32 i;
            AV *out;
            int rc = frd_open((const unsigned char *) p, (size_t) len, &d);
            if (rc != 0) croak("File::Raw::DAWG: %s", frd_strerror(rc));

            /* Group 0 is the empty state and legitimately has none. A
               group past the end is a handle from somewhere else. */
            if (group >= d.nodes) croak("File::Raw::DAWG: %s", frd_strerror(FRD_E_BOUNDS));

            out = newAV();
            if (group != 0) {
                for (i = group; i < d.nodes; i++) {
                    frd_u32 v = frd_rec(&d, i);
                    char letter[2];
                    AV *row;
                    if ((v & FRD_LETTER_MASK) < FRD_MIN_LETTER
                        || (v & FRD_LETTER_MASK) > FRD_MAX_LETTER) {
                        SvREFCNT_dec((SV *) out);
                        croak("File::Raw::DAWG: %s", frd_strerror(FRD_E_BOUNDS));
                    }
                    letter[0] = (char) ('a' + (v & FRD_LETTER_MASK) - 1);
                    letter[1] = '\0';
                    row = newAV();
                    av_push(row, newSVpvn(letter, 1));
                    av_push(row, newSVuv((UV) i));
                    av_push(row, newSViv((v & FRD_TERMINAL_BIT) ? 1 : 0));
                    av_push(out, newRV_noinc((SV *) row));
                    if (v & FRD_LAST_BIT) break;
                }
                if (i >= d.nodes) {
                    SvREFCNT_dec((SV *) out);
                    croak("File::Raw::DAWG: %s", frd_strerror(FRD_E_BOUNDS));
                }
            }
            XPUSHs(sv_2mortal(newRV_noinc((SV *) out)));
        }
