/*
 * walk.c - a consumer of file_raw_dawg.h, with no Perl anywhere.
 *
 * t/04-abi.t compiles this against the INSTALLED header and nothing
 * else: no perl.h, no XSUB.h, no -I to perl's CORE. If it compiles and
 * agrees with the Perl reader, the header really is usable by a C
 * program that knows nothing about this distribution's insides.
 *
 * It prints one fact a line so that a test can assert them.
 *
 * C89, like the header.
 */

#include <stdio.h>
#include <string.h>

#include "file_raw_dawg.h"

static unsigned char buf[1 << 22];

/* The record indices a word visits, printed as it goes. */
static void trace(const frd_dawg *d, const char *word)
{
    frd_u32 group = d->root;
    frd_u32 at = 0;
    size_t i, n = strlen(word);

    printf("trace %s", word);
    for (i = 0; i < n; i++) {
        int rc = frd_step(d, group, (int) word[i] - 'a' + 1, &at);
        if (rc != 0) { printf(" none"); break; }
        printf(" %lu", (unsigned long) at);
        rc = frd_next(d, at, &group);
        if (rc != 0) { group = 0; }
    }
    printf("\n");
}

int main(int argc, char **argv)
{
    FILE *f;
    size_t n;
    frd_dawg d;
    int rc, i;

    if (argc < 2) {
        printf("usage: walk <artifact> [word ...]\n");
        return 2;
    }

    f = fopen(argv[1], "rb");
    if (!f) {
        printf("cannot open %s\n", argv[1]);
        return 3;
    }
    n = fread(buf, 1, sizeof buf, f);
    fclose(f);

    rc = frd_open(buf, n, &d);
    if (rc != 0) {
        printf("refused %d %s\n", rc, frd_strerror(rc));
        return 0;
    }

    printf("opened nodes %lu words %lu root %lu\n",
           (unsigned long) d.nodes,
           (unsigned long) d.words,
           (unsigned long) d.root);

    for (i = 2; i < argc; i++) {
        const unsigned char *w = (const unsigned char *) argv[i];
        size_t len = strlen(argv[i]);
        printf("contains %s %d\n", argv[i], frd_contains(&d, w, len));
        printf("prefix %s %d\n",   argv[i], frd_has_prefix(&d, w, len));
        trace(&d, argv[i]);
    }

    return 0;
}
