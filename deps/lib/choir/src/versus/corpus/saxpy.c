#include <stdint.h>

void kernel_saxpy(int64_t n, const float *a, const float *x, const float *y, float *out) {
    float s = a[0];
    for (int64_t i = 0; i < n; i++) {
        out[i] = s * x[i] + y[i];
    }
}
