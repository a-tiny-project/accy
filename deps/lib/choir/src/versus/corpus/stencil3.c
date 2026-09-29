#include <stdint.h>

void kernel_stencil3(int64_t n, const double *in, double *out) {
    for (int64_t i = 1; i < n - 1; i++) {
        out[i] = 0.25 * in[i - 1] + 0.5 * in[i] + 0.25 * in[i + 1];
    }
}
