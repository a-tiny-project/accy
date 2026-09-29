#include <stdint.h>

void kernel_clampsum(int64_t n, const int64_t *x, int64_t lo, int64_t hi, int64_t *out) {
    int64_t acc = 0;
    for (int64_t i = 0; i < n; i++) {
        int64_t v = x[i];
        if (v < lo) {
            v = lo;
        }
        if (v > hi) {
            v = hi;
        }
        acc += v;
    }
    *out = acc;
}
