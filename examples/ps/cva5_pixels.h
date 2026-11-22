/*
 * The images the PS sends CVA5, as bytes.
 *
 * cva5_pixels.c is GENERATED and is not in git. Build it with:
 *
 *     make -C tools/nn_accel headers
 *
 * which runs tools/nn_accel/export_images.py and writes
 * examples/ps/cva5_pixels.c alongside the two headers examples/sw gets.
 * The same CIFAR images, the same layout, the same labels -- so a result
 * from examples/sw/cifar.c and a result from the PS demo are comparable,
 * and if they differ the difference is the delivery path and nothing else.
 *
 * Bytes rather than words, unlike cva5_image.c: this is pixel data that
 * gets copied into CVA5's image page a byte at a time, R, G, B, 0 per
 * pixel, and the four-bytes-per-pixel layout is the point of it. See
 * ACCEL_PIXEL_BYTES in examples/sw/soc.h.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CVA5_PIXELS_H
#define CVA5_PIXELS_H

#include <stdint.h>

/* cva5_pixel_images * JOB_IMG_SIZE bytes, image k at k * JOB_IMG_SIZE. */
extern const uint8_t  cva5_pixels[];
extern const uint32_t cva5_pixel_images;
extern const uint8_t  cva5_pixel_labels[];
extern const char *const cva5_pixel_classes[2];

#endif /* CVA5_PIXELS_H */
