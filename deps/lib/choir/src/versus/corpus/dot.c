#include <stdint.h>

void kernel_dot(int64_t n, const double *x, const double *y, double *out) {
    double acc = 0.0;
    for (int64_t i = 0; i < n; i++) {
        acc += x[i] * y[i];
    }
    *out = acc;
}
