/* Minimal stdio for the CVA5 examples. No libc in the toolchain.
 *
 *   puts()   -> puts.c
 *   printf() -> printf.c   %d %u %s %c %x %%, with field width and the
 *                          '-' (left align) and '0' (zero pad) flags
 *
 * No floating point: CVA5 is RV32IM, and soft-float would both bloat the
 * image and distort any cycle counts being measured. */
int puts(const char *);
int printf(const char *fmt, ...);
