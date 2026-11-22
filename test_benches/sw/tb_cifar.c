/*
 * tb_cifar -- examples/sw/cifar.c's software reference, on the host, against
 * an independent model of the same arithmetic.
 *
 * cifar.c exists to tell the board whether the accelerator computed the
 * right thing. That makes its own correctness load-bearing in a way a
 * driver's usually is not: if its indexing is wrong, every image
 * "disagrees", and the search goes looking for a hardware fault that is not
 * there. So the reference needs a reference.
 *
 * The one here is gen_cifar_fixture.py, written from the PyTorch semantics
 * -- Conv2d weights [out][in][kh][kw], padding 1, MaxPool2d(4), Flatten
 * channel-major -- rather than from this C, and structured the other way
 * round: it pads the input and convolves the whole map where cifar.c
 * bounds-tests and fuses the pooling in. Both see the same pseudo-random
 * weights and images; agreement on every logit means two independently
 * written sets of index expressions pick the same numbers.
 *
 * Standard library only. This has to run in a clone where the accelerator
 * toolchain has never been set up -- a test that needs a venv built first
 * is a test that does not get run.
 *
 * What this cannot check is the accelerator, or whether the quantization
 * matches the trained model. It checks the one thing that would otherwise
 * be checked only by the hardware it is meant to judge.
 *
 * Run from the repo root: sh test_benches/sw/run_cifar.sh
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdio.h>
#include <stdlib.h>

/* cifar.c prints through the examples' own two-line stdio. Give it one. */
void putstr(const char *s) { fputs(s, stdout); }

/* cifar.c's main() would talk to a register window that does not exist here.
 * Rename it rather than #ifdef the production file: nothing calls it, and
 * the compiler still parses and type-checks all of it, which is worth
 * keeping. */
#define main cifar_main
#include "cifar.c"
#undef main

#include "expected.h"

/*
 * The fixture's image count against the one cifar.c was actually compiled
 * against.
 *
 * These come apart in one specific way, and it is silent. A quoted #include
 * searches the including file's own directory first, ahead of every -iquote
 * and -I, so a cifar.c compiled in examples/sw finds the images.h a real
 * `make -C tools/nn_accel headers` left there rather than the fixture's.
 * The test then runs the trained network and compares it against the
 * fixture's answers: every check fails, and nothing says why. run_cifar.sh
 * compiles a copy of cifar.c in the fixture directory to avoid it; this
 * fails the build if that ever stops working.
 */
typedef char tb_cifar_fixture_count[(N_IMAGES == FIXTURE_N_IMAGES) ? 1 : -1];

static int checks = 0, failures = 0;

/*
 * The count above only catches an export of a *different* size, which the
 * compiler catches by itself. This catches one of the same size, which is
 * the silent case: every logit then differs, by amounts that look like a
 * hardware fault rather than a build fault.
 */
#define SUMOF(a) do { unsigned i_; \
    for (i_ = 0; i_ < sizeof(a) / sizeof((a)[0]); i_++) \
        wsum += (unsigned long long)(long long)(a)[i_]; } while (0)

static void check_fixture(void) {
    unsigned long long isum = 0, wsum = 0;
    int k;
    unsigned i;

    for (k = 0; k < N_IMAGES; k++)
        for (i = 0; i < IMG_BYTES; i++)
            isum += IMAGES[k][i];
    SUMOF(W1); SUMOF(B1); SUMOF(W2); SUMOF(B2); SUMOF(W3); SUMOF(B3);

    checks += 2;
    if (isum != FIXTURE_IMAGE_SUM) {
        failures++;
        printf("  FAIL images are not the fixture's -- cifar.c compiled"
               " against a real export\n");
    }
    if (wsum != FIXTURE_WEIGHT_SUM) {
        failures++;
        printf("  FAIL weights are not the fixture's -- cifar.c compiled"
               " against a real export\n");
    }
    if (isum != FIXTURE_IMAGE_SUM || wsum != FIXTURE_WEIGHT_SUM)
        printf("       (a quoted #include searches the including file's own"
               " directory first;\n"
               "        run_cifar.sh compiles a copy of cifar.c beside the"
               " fixture to avoid it)\n");
}

static void check_eq(const char *what, int k, int got, int want) {
    checks++;
    if (got != want) {
        failures++;
        printf("  FAIL image %d %s: got %d, want %d\n", k, what, got, want);
    }
}

int main(void) {
    int k, l0, l1;

    printf("tb_cifar: cifar.c's sw_infer against an independent model of"
           " the same arithmetic\n");

    /* Before anything else: that the thing being tested and the answers it
     * is tested against came from the same fixture. */
    check_fixture();
    if (failures) {
        printf("FAIL tb_cifar: wrong headers, remaining checks skipped\n");
        return 1;
    }

    for (k = 0; k < N_IMAGES; k++) {
        sw_infer(IMAGES[k], &l0, &l1);
        check_eq("logit 0", k, l0, EXPECTED[k][0]);
        check_eq("logit 1", k, l1, EXPECTED[k][1]);
        /* The decision, separately: two logits can both be wrong by the same
         * amount and still argmax correctly, which would hide a scale error
         * that matters to nothing here but would matter to a third layer. */
        check_eq("argmax", k, (l1 > l0) ? 1 : 0,
                 (EXPECTED[k][1] > EXPECTED[k][0]) ? 1 : 0);
    }

    /* The fixture is built to exercise both classes and the saturating edge
     * of relu; a run where every logit came out zero would pass every
     * comparison above and mean nothing. */
    checks++;
    {
        int nonzero = 0;
        for (k = 0; k < N_IMAGES; k++)
            if (EXPECTED[k][0] != 0 || EXPECTED[k][1] != 0) nonzero++;
        if (nonzero < N_IMAGES) {
            failures++;
            printf("  FAIL fixture: %d of %d images produce all-zero logits\n",
                   N_IMAGES - nonzero, N_IMAGES);
        }
    }

    printf("%s tb_cifar: %d checks, %d failures\n",
           failures ? "FAIL" : "PASS", checks, failures);
    return failures ? 1 : 0;
}
