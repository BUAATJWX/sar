#include "grad_h.h"

#if MATLAB_MEX_FILE
#include "mex.h"
#define PRINTF mexPrintf
#else
#define PRINTF printf
#endif

#include <cmath>
#include <vector>
#include <thread>
#include <assert.h>

#include <cuda_runtime.h>

using namespace std;

// Convenience function for checking CUDA runtime API results
// can be wrapped around any runtime API call. No-op in release builds.
  inline
cudaError_t checkCuda(cudaError_t result)
{
#if defined(DEBUG) || defined(_DEBUG)
  if (result != cudaSuccess) {
    fprintf(stderr, "CUDA Runtime Error: %s\n", cudaGetErrorString(result));
    assert(result == cudaSuccess);
  }
#endif
  return result;
}

  template<typename T>
__global__ void kernelSum(const T * __restrict__ Br, const T * __restrict__ Bi, 
    const size_t nrows, T * __restrict__ Z_mag, const T * __restrict__ P)
{
  extern __shared__ T sdata[];

  T *s1 = sdata, *s2 = &sdata[blockDim.x];

  T x(0.0), y(0.0);

  const T * Br_col = &Br[blockIdx.x * nrows];
  const T * Bi_col = &Bi[blockIdx.x * nrows];

  // Accumulate per thread partial sum
  for (int i = threadIdx.x; i < nrows; i += blockDim.x) {
    x += Br_col[i] * cos(P[i % nrows]) + Bi_col[i] * sin(P[i % nrows]);
    y += Bi_col[i] * cos(P[i % nrows]) - Br_col[i] * sin(P[i % nrows]);
  }

  // load thread partial sum into shared memory
  s1[threadIdx.x] = x;
  s2[threadIdx.x] = y;

  __syncthreads();

  for (int offset = blockDim.x / 2; offset > 0; offset >>= 1) {
    if (threadIdx.x < offset) {
      s1[threadIdx.x] += s1[threadIdx.x + offset];
      s2[threadIdx.x] += s2[threadIdx.x + offset];
    }
    __syncthreads();
  }

  // thread 0 writes the final result
  if (threadIdx.x == 0) {
    Z_mag[blockIdx.x] = s1[0] * s1[0] + s2[0] * s2[0];
  }
}

template<class T>
struct SharedMemory
{
  __device__ inline operator       T *()
  {
    extern __shared__ int __smem[];
    return (T *)__smem;
  }

  __device__ inline operator const T *() const
  {
    extern __shared__ int __smem[];
    return (T *)__smem;
  }
};

template<>
struct SharedMemory<double>
{
  __device__ inline operator       double *()
  {
    extern __shared__ double __smem_d[];
    return (double *)__smem_d;
  }

  __device__ inline operator const double *() const
  {
    extern __shared__ double __smem_d[];
    return (double *)__smem_d;
  }
};

template <class T>
__global__ void sum(T *g_idata, T *g_odata, unsigned int n)
{
  T *sdata = SharedMemory<T>();

  // load shared mem
  unsigned int tid = threadIdx.x;
  unsigned int i = blockIdx.x*blockDim.x + threadIdx.x;

  sdata[tid] = (i < n) ? g_idata[i] : 0;

  __syncthreads();

  // do reduction in shared mem
  for (unsigned int s=1; s < blockDim.x; s *= 2)
  {
    // modulo arithmetic is slow!
    if ((tid % (2*s)) == 0)
    {
      sdata[tid] += sdata[tid + s];
    }

    __syncthreads();
  }

  // write result for this block to global mem
  if (tid == 0) g_odata[blockIdx.x] = sdata[0];
}

template <class T>
__global__ void computeEntropy(T *g_idata, T *g_odata, double Ez, unsigned int n)
{
  T *sdata = SharedMemory<T>();

  // load shared mem
  unsigned int tid = threadIdx.x;
  unsigned int i = blockIdx.x*blockDim.x + threadIdx.x;

  sdata[tid] = (i < n) ? (g_idata[i] / Ez) * log(g_idata[i] / Ez) : 0;

  __syncthreads();

  // do reduction in shared mem
  for (unsigned int s=1; s < blockDim.x; s *= 2)
  {
    // modulo arithmetic is slow!
    if ((tid % (2*s)) == 0)
    {
      sdata[tid] += sdata[tid + s];
    }

    __syncthreads();
  }

  // write result for this block to global mem
  if (tid == 0) g_odata[blockIdx.x] = sdata[0];
}

// Returns the entropy of the complex image `Z`
double H(const vector<double> P, const double *Br, const double *Bi,
    double *d_Br, double *d_Bi, size_t K, size_t B_len,
    cudaStream_t *stream, int nStreams, int streamSize)
{
  const int nT = 1024;

  size_t N = B_len / K;
  double Ez(0), entropy(0);

  assert(B_len % K == 0); // length(B) should always be a multiple of K

  double *d_P, *d_Z_mag = NULL;

  // TODO: Use pinned memory
  checkCuda(cudaMalloc((void **)&d_P,  K * sizeof(double)));

  checkCuda(cudaMemcpyAsync(d_P, &P[0], K * sizeof(double), cudaMemcpyHostToDevice, 0));

  checkCuda(cudaMalloc((void **)&d_Z_mag, N * sizeof(double)));

  for (int i = 0; i < nStreams; ++i) {
    int offset = i * streamSize;
    int Z_offset = i * (N / nStreams);

    kernelSum<double><<<N / nStreams, nT, 2 * nT * sizeof(double), stream[i]>>>(&d_Br[offset], &d_Bi[offset], K, &d_Z_mag[Z_offset], d_P);
  }

  int bs = (N + nT - 1) / nT; // cheap ceil()

  double *accum   = NULL;
  double *d_accum = NULL;

  checkCuda(cudaMallocHost((void **)&accum, bs * sizeof(double)));
  checkCuda(cudaMalloc((void **)&d_accum, bs * sizeof(double)));

  sum<double><<<bs, nT, nT * sizeof(double)>>>(d_Z_mag, d_accum, N);
  checkCuda(cudaMemcpy(accum, d_accum, bs * sizeof(double), cudaMemcpyDeviceToHost));
  for (size_t b(0); b < bs; ++b) { Ez += accum[b]; }


  computeEntropy<double><<<bs, nT, nT * sizeof(double)>>>(d_Z_mag, d_accum, Ez, N);
  checkCuda(cudaMemcpy(accum, d_accum, bs * sizeof(double), cudaMemcpyDeviceToHost));
  for (size_t b(0); b < bs; ++b) { entropy += accum[b]; }

  checkCuda(cudaFree(d_P));

  checkCuda(cudaFree(d_Z_mag));
  checkCuda(cudaFree(d_accum));

  checkCuda(cudaFreeHost(accum));

  return - entropy;
}

// TODO: Nice doc comments
void gradH(double *phi_offsets, const double *Br, const double *Bi,
    double *grad, size_t K, size_t B_len)
{
  vector<double> P(phi_offsets, phi_offsets + K);

  const int nStreams = 8;
  const int streamSize = B_len / nStreams;

  cudaStream_t stream[nStreams];

  for (int i = 0; i < nStreams; ++i)
    checkCuda(cudaStreamCreate(&stream[i]));

  double *d_Br, *d_Bi;

  // TODO: Use pinned memory
  checkCuda(cudaMalloc((void **)&d_Br, B_len * sizeof(double)));
  checkCuda(cudaMalloc((void **)&d_Bi, B_len * sizeof(double)));

  for (int i = 0; i < nStreams; ++i) {
    int offset = i * streamSize;

    checkCuda(cudaMemcpyAsync(&d_Br[offset], &Br[offset], streamSize * sizeof(double), cudaMemcpyHostToDevice, stream[i]));
    checkCuda(cudaMemcpyAsync(&d_Bi[offset], &Bi[offset], streamSize * sizeof(double), cudaMemcpyHostToDevice, stream[i]));
  }

  PRINTF("In gradH, about to compute Z\n");
  PRINTF("Computed Z\n");
  double H_not = H(P, Br, Bi, d_Br, d_Bi, K, B_len, stream, nStreams, streamSize);
  PRINTF("Computed H_not\n");

  auto Pr_k(P.begin());

  while (Pr_k != P.end()) {
    if (Pr_k != P.begin()) {
      *(Pr_k - 1) -= delta;
    }

    *Pr_k++ += delta;

    double H_i = H(P, Br, Bi, d_Br, d_Bi, K, B_len, stream, nStreams, streamSize);
    *grad++ = (H_i - H_not) / delta;
  }

  checkCuda(cudaFree(d_Br));
  checkCuda(cudaFree(d_Bi));

  for (int i = 0; i < nStreams; ++i)
    checkCuda(cudaStreamDestroy(stream[i]));
}
