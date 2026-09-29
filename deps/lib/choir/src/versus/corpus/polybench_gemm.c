#include <stdint.h>

void kernel_gemm(int ni, int nj, int nk, double alpha, double beta, double C[ni][nj],
                 double A[ni][nk], double B[nk][nj]) {
    int i, j, k;
    for (i = 0; i < ni; i++) {
        for (j = 0; j < nj; j++)
            C[i][j] *= beta;
        for (k = 0; k < nk; k++) {
            for (j = 0; j < nj; j++)
                C[i][j] += alpha * A[i][k] * B[k][j];
        }
    }
}
