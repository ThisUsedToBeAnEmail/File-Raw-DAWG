/*
 * dawg_build.c - incremental construction of a minimal acyclic automaton
 * from sorted input.
 *
 * Daciuk, Mihov, Watson and Watson, "Incremental Construction of Minimal
 * Acyclic Finite-State Automata", Computational Linguistics 26(1), 2000,
 * section 3: the version that requires sorted input and holds only the
 * current path plus the register, which is why this builder's memory is
 * bounded by the size of the automaton and not by the size of the list.
 *
 * A state's identity here is its outgoing transition run and nothing
 * else. Terminality lives on the arriving transition rather than in the
 * state, so two states with the same run are the same run even when one
 * ends a word and the other does not: the parents' terminal bits carry
 * the difference. That is a property of the format, not a shortcut.
 *
 * Records are held packed and little-endian, exactly as they go to disk,
 * so the register compares byte runs and the caller writes what it is
 * given. Nothing here knows the host's byte order.
 *
 * No Perl. C89.
 */

#include <stdlib.h>
#include <string.h>

#include "dawg_build.h"

typedef struct {
    unsigned char letter;     /* 1 to 26 */
    unsigned char terminal;
    frd_u32       child;      /* record index of the target's group, 0 for none */
} frd_edge;

typedef struct {
    frd_edge edge[FRD_MAX_LETTER];
    int      count;
} frd_state;

typedef struct {
    frd_u32 index;            /* where the group starts, in records */
    frd_u32 len;              /* how many records it is */
    frd_u32 hash;
    int     used;
} frd_slot;

struct frd_builder {
    frd_state     path[FRD_MAX_WORD + 1];
    unsigned char prev[FRD_MAX_WORD];
    int           depth;      /* the length of the previous word */

    unsigned char *rec;       /* packed records, index 0 is the sentinel */
    frd_u32        rec_len;   /* in records */
    frd_u32        rec_cap;   /* in records */

    frd_slot      *slot;      /* the register, open addressing */
    frd_u32        slot_used;
    frd_u32        slot_cap;  /* a power of two */

    frd_u32 words;
    frd_u32 root;
    int     finished;
    int     err;
};

static void frd_put(unsigned char *p, frd_u32 v)
{
    p[0] = (unsigned char) ( v        & 0xFFU);
    p[1] = (unsigned char) ((v >>  8) & 0xFFU);
    p[2] = (unsigned char) ((v >> 16) & 0xFFU);
    p[3] = (unsigned char) ((v >> 24) & 0xFFU);
}

static frd_u32 frd_hash_bytes(const unsigned char *p, size_t n)
{
    /* FNV-1a, 32 bit. Masked because frd_u32 may be wider. */
    frd_u32 h = 2166136261U;
    size_t i;
    for (i = 0; i < n; i++) {
        h ^= (frd_u32) p[i];
        h = (h * 16777619U) & 0xFFFFFFFFU;
    }
    return h;
}

static int frd_grow_records(frd_builder *b, frd_u32 want)
{
    unsigned char *fresh;
    frd_u32 cap;
    if (want <= b->rec_cap) return FRD_B_OK;
    cap = b->rec_cap ? b->rec_cap : 256;
    while (cap < want) {
        if (cap > FRD_MAX_NODES) return FRD_B_OVERFLOW;
        cap *= 2;
    }
    fresh = (unsigned char *) realloc(b->rec, (size_t) cap * FRD_REC_LEN);
    if (!fresh) return FRD_B_MEM;
    b->rec = fresh;
    b->rec_cap = cap;
    return FRD_B_OK;
}

static int frd_register_put(frd_builder *b, frd_u32 hash, frd_u32 index, frd_u32 len);

static int frd_register_grow(frd_builder *b)
{
    frd_slot *old = b->slot;
    frd_u32 old_cap = b->slot_cap;
    frd_u32 cap = old_cap ? old_cap * 2 : 1024;
    frd_u32 i;
    int rc;

    b->slot = (frd_slot *) calloc((size_t) cap, sizeof(frd_slot));
    if (!b->slot) { b->slot = old; return FRD_B_MEM; }
    b->slot_cap = cap;
    b->slot_used = 0;

    for (i = 0; i < old_cap; i++) {
        if (!old[i].used) continue;
        rc = frd_register_put(b, old[i].hash, old[i].index, old[i].len);
        if (rc != FRD_B_OK) { free(b->slot); b->slot = old; b->slot_cap = old_cap; return rc; }
    }
    free(old);
    return FRD_B_OK;
}

static int frd_register_put(frd_builder *b, frd_u32 hash, frd_u32 index, frd_u32 len)
{
    frd_u32 mask, at;
    if (b->slot_cap == 0) {
        int rc = frd_register_grow(b);
        if (rc != FRD_B_OK) return rc;
    }
    mask = b->slot_cap - 1;
    at = hash & mask;
    while (b->slot[at].used) at = (at + 1) & mask;
    b->slot[at].used  = 1;
    b->slot[at].hash  = hash;
    b->slot[at].index = index;
    b->slot[at].len   = len;
    b->slot_used++;
    return FRD_B_OK;
}

/* The record index of a group identical to the candidate, or 0. */
static frd_u32 frd_register_get(const frd_builder *b, frd_u32 hash,
                                const unsigned char *want, frd_u32 len)
{
    frd_u32 mask, at;
    if (b->slot_cap == 0) return 0;
    mask = b->slot_cap - 1;
    at = hash & mask;
    while (b->slot[at].used) {
        if (b->slot[at].hash == hash && b->slot[at].len == len
            && memcmp(b->rec + (size_t) b->slot[at].index * FRD_REC_LEN,
                      want, (size_t) len * FRD_REC_LEN) == 0) {
            return b->slot[at].index;
        }
        at = (at + 1) & mask;
    }
    return 0;
}

/*
 * A state becomes a run of records: the one already in the register, or
 * a fresh one appended. A state with no transitions is the empty state
 * and is record 0, the sentinel, which is why it costs nothing.
 */
static frd_u32 frd_freeze(frd_builder *b, frd_state *s)
{
    unsigned char want[FRD_MAX_LETTER * FRD_REC_LEN];
    frd_u32 hash, found, index;
    int i;
    int rc;

    if (s->count == 0) return 0;

    for (i = 0; i < s->count; i++) {
        frd_u32 v = (frd_u32) s->edge[i].letter;
        if (s->edge[i].terminal)  v |= FRD_TERMINAL_BIT;
        if (i == s->count - 1)    v |= FRD_LAST_BIT;
        v |= (frd_u32) s->edge[i].child << FRD_CHILD_SHIFT;
        frd_put(want + (size_t) i * FRD_REC_LEN, v);
    }

    hash = frd_hash_bytes(want, (size_t) s->count * FRD_REC_LEN);
    found = frd_register_get(b, hash, want, (frd_u32) s->count);
    if (found) return found;

    if (b->rec_len + (frd_u32) s->count > FRD_MAX_NODES) {
        b->err = FRD_B_OVERFLOW;
        return 0;
    }
    rc = frd_grow_records(b, b->rec_len + (frd_u32) s->count);
    if (rc != FRD_B_OK) { b->err = rc; return 0; }

    index = b->rec_len;
    memcpy(b->rec + (size_t) index * FRD_REC_LEN, want,
           (size_t) s->count * FRD_REC_LEN);
    b->rec_len += (frd_u32) s->count;

    if ((b->slot_used + 1) * 10 >= b->slot_cap * 7) {
        rc = frd_register_grow(b);
        if (rc != FRD_B_OK) { b->err = rc; return 0; }
    }
    rc = frd_register_put(b, hash, index, (frd_u32) s->count);
    if (rc != FRD_B_OK) { b->err = rc; return 0; }

    return index;
}

frd_builder *frd_builder_new(void)
{
    frd_builder *b = (frd_builder *) calloc(1, sizeof(frd_builder));
    if (!b) return NULL;
    if (frd_grow_records(b, 1) != FRD_B_OK) { free(b); return NULL; }
    /* Record 0 is the sentinel and is all zero bits. */
    frd_put(b->rec, 0);
    b->rec_len = 1;
    return b;
}

void frd_builder_free(frd_builder *b)
{
    if (!b) return;
    free(b->rec);
    free(b->slot);
    free(b);
}

int frd_builder_add(frd_builder *b, const unsigned char *word, size_t len)
{
    int p, i, order;
    size_t n;

    if (b->finished) return FRD_B_STATE;
    if (len == 0 || len > FRD_MAX_WORD) return FRD_B_LONG;

    for (i = 0; i < (int) len; i++) {
        if (word[i] < 'a' || word[i] > 'z') return FRD_B_CHARSET;
    }

    /* Strictly ascending, so a repeat is refused along with a reversal. */
    order = 0;
    n = (size_t) b->depth < len ? (size_t) b->depth : len;
    for (i = 0; i < (int) n; i++) {
        if (b->prev[i] != word[i]) {
            order = b->prev[i] < word[i] ? -1 : 1;
            break;
        }
    }
    if (order == 0) order = (size_t) b->depth < len ? -1
                          : ((size_t) b->depth == len ? 0 : 1);
    if (b->words > 0 && order >= 0) return FRD_B_ORDER;

    p = 0;
    while (p < b->depth && p < (int) len && b->prev[p] == word[p]) p++;

    for (i = b->depth; i > p; i--) {
        frd_u32 child = frd_freeze(b, &b->path[i]);
        if (b->err) return b->err;
        b->path[i - 1].edge[b->path[i - 1].count - 1].child = child;
    }

    for (i = p; i < (int) len; i++) {
        frd_state *s = &b->path[i];
        if (s->count >= FRD_MAX_LETTER) return FRD_B_CHARSET;
        s->edge[s->count].letter   = (unsigned char) (word[i] - 'a' + 1);
        s->edge[s->count].terminal = (i == (int) len - 1) ? 1 : 0;
        s->edge[s->count].child    = 0;
        s->count++;
        b->path[i + 1].count = 0;
    }

    memcpy(b->prev, word, len);
    b->depth = (int) len;
    b->words++;
    return FRD_B_OK;
}

int frd_builder_finish(frd_builder *b)
{
    int i;
    if (b->finished) return FRD_B_STATE;

    for (i = b->depth; i > 0; i--) {
        frd_u32 child = frd_freeze(b, &b->path[i]);
        if (b->err) return b->err;
        b->path[i - 1].edge[b->path[i - 1].count - 1].child = child;
    }

    b->root = frd_freeze(b, &b->path[0]);
    if (b->err) return b->err;

    b->finished = 1;
    return FRD_B_OK;
}

const void *frd_builder_records(const frd_builder *b)
{
    return b->finished ? (const void *) b->rec : NULL;
}

frd_u32 frd_builder_node_count(const frd_builder *b) { return b->rec_len; }
frd_u32 frd_builder_word_count(const frd_builder *b) { return b->words; }
frd_u32 frd_builder_root(const frd_builder *b)       { return b->root; }

const char *frd_builder_strerror(int code)
{
    switch (code) {
        case FRD_B_OK:       return "no error";
        case FRD_B_ORDER:    return "out of order, or a repeat of the word before";
        case FRD_B_CHARSET:  return "a letter outside a to z";
        case FRD_B_LONG:     return "empty, or longer than the word cap";
        case FRD_B_OVERFLOW: return "more records than the format can index";
        case FRD_B_MEM:      return "out of memory";
        case FRD_B_STATE:    return "the builder was used out of order";
        default:             return "unknown error";
    }
}
