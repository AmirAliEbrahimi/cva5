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
 * The one here is NumPy, in run_cifar.sh, written from the PyTorch
 * semantics -- Conv2d weights [out][in][kh][kw], padding 1, MaxPool2d(4),
 * Flatten channel-major -- rather than from this C. Both see the same
 * pseudo-random weights and images; agreement on every logit means the two
 * independently-written index expressions pick the same numbers.
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

static int checks = 0, failures = 0;

static void check_eq(const char *what, int k, int got, int want) {
    checks++;
    if (got != want) {
        failures++;
        printf("  FAIL image %d %s: got %d, want %d\n", k, what, got, want);
    }
}

int main(void) {
    int k, l0, l1;

    printf("tb_cifar: cifar.c's sw_infer against a NumPy model of the same"
           " arithmetic\n");

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
