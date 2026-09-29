#include <stdint.h>

void kernel_sum(int64_t n, const int64_t *x, int64_t *out) {
    int64_t acc = 0;
    for (int64_t i = 0; i < n; i++) {
        acc += x[i];
    }
    *out = acc;
}
