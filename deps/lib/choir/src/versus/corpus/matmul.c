#include <stdint.h>

void kernel_matmul(int64_t n, const double *a, const double *b, double *c) {
    for (int64_t i = 0; i < n; i++) {
        for (int64_t j = 0; j < n; j++) {
            double acc = 0.0;
            for (int64_t k = 0; k < n; k++) {
                acc += a[i * n + k] * b[k * n + j];
            }
            c[i * n + j] = acc;
        }
    }
}
