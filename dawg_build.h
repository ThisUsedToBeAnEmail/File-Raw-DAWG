/*
 * dawg_build.h - building a File::Raw::DAWG artifact.
 *
 * PRIVATE to this distribution. It is not installed and no consumer may
 * rely on it; include/file_raw_dawg.h is the public one. A consumer
 * builds an artifact by calling File::Raw::DAWG->build, not by calling
 * these.
 *
 * No Perl in here or in dawg_build.c: the algorithm is plain C and the
 * XS is what croaks. C89 throughout.
 */

#ifndef DAWG_BUILD_H
#define DAWG_BUILD_H

#include <stddef.h>
#include "file_raw_dawg.h"

/*
 * The longest word the builder accepts. ENABLE's longest is 28. The cap
 * is what keeps the current path a fixed allocation rather than a
 * growing one, which is most of why the builder's memory is bounded by
 * the automaton and not by the list.
 */
#define FRD_MAX_WORD 64

#define FRD_B_OK        0
#define FRD_B_ORDER   (-1)   /* out of order, or equal to the word before */
#define FRD_B_CHARSET (-2)   /* something outside a to z */
#define FRD_B_LONG    (-3)   /* empty, or longer than FRD_MAX_WORD */
#define FRD_B_OVERFLOW (-4)  /* more records than FRD_MAX_NODES */
#define FRD_B_MEM     (-5)   /* out of memory */
#define FRD_B_STATE   (-6)   /* added after finish, or read before it */

typedef struct frd_builder frd_builder;

frd_builder *frd_builder_new(void);
void         frd_builder_free(frd_builder *b);

/* Words must arrive sorted ascending and unique. Returns FRD_B_*. */
int frd_builder_add(frd_builder *b, const unsigned char *word, size_t len);

/* Freezes what is left and settles the root. Returns FRD_B_*. */
int frd_builder_finish(frd_builder *b);

/* Only after a successful finish. */
const void *frd_builder_records(const frd_builder *b);   /* 4 * node_count bytes */
frd_u32     frd_builder_node_count(const frd_builder *b);
frd_u32     frd_builder_word_count(const frd_builder *b);
frd_u32     frd_builder_root(const frd_builder *b);

/* A short English phrase for a FRD_B_* code. Never NULL. */
const char *frd_builder_strerror(int code);

#endif /* DAWG_BUILD_H */
