/* printf.c — minimal printf for the CVA5 examples.
 *
 * The toolchain is -nostdlib, and puts.c provides only puts(). This adds just
 * enough printf for the accelerator driver: %d %u %s %c %x %% with optional
 * field width, '-' left-align and '0' zero-pad (e.g. %2d, %-10s, %03d).
 *
 * No floats: CVA5 is RV32IM, and pulling in soft-float would distort the very
 * cycle counts the driver exists to measure.
 *
 * Same UART as puts.c: AXI UART Lite at 0x60000000.
 *
 * VERIFIED: output compared character-for-character against glibc printf for
 * every format string used by examples/sw/bench.c.
 */

#include <stdarg.h>

#define UART_BASE 0x60000000u
#define UART_TX   (*(volatile unsigned int *)(UART_BASE + 0x04u))
#define UART_STAT (*(volatile unsigned int *)(UART_BASE + 0x08u))
#define TX_FULL   (1u << 3)

static void putc_(char c) {
    while (UART_STAT & TX_FULL) ;
    UART_TX = (unsigned char)c;
}

/* unsigned -> decimal or hex digits, returns length written to buf */
static int utoa_(unsigned int v, char *buf, unsigned int base) {
    char tmp[12];
    int n = 0;
    if (v == 0) tmp[n++] = '0';
    while (v) {
        unsigned int d = v % base;
        tmp[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
        v /= base;
    }
    for (int i = 0; i < n; i++)
        buf[i] = tmp[n - 1 - i];
    return n;
}

static void pad_(int count, char c) {
    while (count-- > 0) putc_(c);
}

int printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);

    int written = 0;

    while (*fmt) {
        if (*fmt != '%') { putc_(*fmt++); written++; continue; }
        fmt++;

        int left = 0;
        if (*fmt == '-') { left = 1; fmt++; }

        /* '0' flag must be consumed before the width digits, otherwise a
         * format like %03d parses the leading zero as part of the width and
         * pads with spaces. */
        int zero = 0;
        if (*fmt == '0') { zero = 1; fmt++; }

        int width = 0;
        while (*fmt >= '0' && *fmt <= '9')
            width = width * 10 + (*fmt++ - '0');

        /* accept and ignore length modifiers */
        while (*fmt == 'l' || *fmt == 'h') fmt++;

        char buf[12];
        int len = 0;
        const char *src = buf;
        char sign = 0;

        switch (*fmt) {
        case 'd': {
            int v = va_arg(ap, int);
            unsigned int mag;
            if (v < 0) { sign = '-'; mag = (unsigned int)(-(long)v); }
            else       { mag = (unsigned int)v; }
            len = utoa_(mag, buf, 10);
            break;
        }
        case 'u':
            len = utoa_(va_arg(ap, unsigned int), buf, 10);
            break;
        case 'x':
            len = utoa_(va_arg(ap, unsigned int), buf, 16);
            break;
        case 'c':
            buf[0] = (char)va_arg(ap, int);
            len = 1;
            break;
        case 's': {
            src = va_arg(ap, const char *);
            if (!src) src = "(null)";
            const char *p = src;
            while (*p) p++;
            len = (int)(p - src);
            break;
        }
        case '%':
            buf[0] = '%';
            len = 1;
            break;
        case '\0':
            va_end(ap);
            return written;
        default:                      /* unknown: emit literally */
            putc_('%');
            putc_(*fmt);
            written += 2;
            fmt++;
            continue;
        }
        fmt++;

        int total = len + (sign ? 1 : 0);
        /* sign goes before zero padding, spaces before the sign */
        if (zero && sign) { putc_(sign); written++; sign = 0; }
        if (!left) pad_(width - total, zero ? '0' : ' ');
        if (sign) { putc_(sign); written++; }
        for (int i = 0; i < len; i++) putc_(src[i]);
        written += len;
        if (left) pad_(width - total, ' ');
        if (width > total) written += (width - total);
    }

    va_end(ap);
    return written;
}
