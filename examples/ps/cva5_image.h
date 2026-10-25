/*
 * The CVA5 program the PS loads, as a word array.
 *
 * cva5_image.c is GENERATED and is not in git. Build it with:
 *
 *     make -C examples/sw ps-image PS_APP=timer.elf
 *
 * which runs tools/elf-to-c-array.py over the ELF and writes
 * examples/ps/cva5_image.c. Any of the examples works -- timer.elf, plic.elf,
 * memtest.elf -- because they all link at RAM_BASE as one contiguous image
 * (examples/sw/fpga_link.ld), so a flat objcopy of the ELF written at offset
 * zero is the whole program. There are no segments to walk, which is why
 * there is no ELF parser anywhere in this flow.
 *
 * A word array rather than bytes: the AXI port is 32 bits, the array is
 * naturally aligned, and the copy loop is then a plain word store with no
 * endianness to think about.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CVA5_IMAGE_H
#define CVA5_IMAGE_H

#include <stdint.h>

extern const uint32_t cva5_image[];
extern const uint32_t cva5_image_words;

#endif /* CVA5_IMAGE_H */
