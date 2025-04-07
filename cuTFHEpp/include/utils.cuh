#pragma once

#include "types.h"

#define CUDA_CHECK_RETURN(value)                                    \
  {                                                                 \
    cudaError_t _m_cudaStat = value;                                \
    if (_m_cudaStat != cudaSuccess) {                               \
      fprintf(stderr, "Error %s at line %d in file %s\n",           \
              cudaGetErrorString(_m_cudaStat), __LINE__, __FILE__); \
      abort();                                                      \
    }                                                               \
  }

#define CUDA_CHECK_ERROR()                                          \
  {                                                                 \
    cudaError_t _m_cudaStat = cudaGetLastError();                   \
    if (_m_cudaStat != cudaSuccess) {                               \
      fprintf(stderr, "Error %s at line %d in file %s\n",           \
              cudaGetErrorString(_m_cudaStat), __LINE__, __FILE__); \
      abort();                                                      \
    }                                                               \
  }

#define RECORD_TIME_START(start, stop) { \
  cudaEventCreate(&start); \
  cudaEventCreate(&stop); \
  cudaEventRecord(start, 0); }

#define RECORD_TIME_END(start, stop) ({ \
  cudaDeviceSynchronize(); \
  float et; \
  cudaEventRecord(stop, 0); \
  cudaEventSynchronize(stop); \
  cudaEventElapsedTime(&et, start, stop); \
  cudaEventDestroy(start); \
  cudaEventDestroy(stop); \
  et; \
})

namespace cuTFHEpp
{
  template<typename P>
    __global__ void mu_polygen(TFHEpp::Polynomial<P> &testvector, typename P::T mu)
    {
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      for (int i = tid; i < P::n; i += bdim) testvector[i] = mu;
    }

#define CUTFHEPP_MU_POLYGEN(X)                   \
  template __global__ void mu_polygen<Lvl##X>(   \
      TFHEpp::Polynomial<Lvl##X> &testvector,    \
      typename Lvl##X::T mu);

  EXPLICIT_LVL_EXTERN(CUTFHEPP_MU_POLYGEN);

  template<typename P, uint32_t plain_bits>
  __global__ void gpolygen(TFHEpp::Polynomial<P> &testvector, uint32_t scale_bits)
  {
    const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
    const unsigned int bdim = blockDim.x*blockDim.y;

    constexpr uint32_t padding_bits = P::nbit - plain_bits;

    for (int i = tid; i < P::n; i += bdim) testvector[i] = (1ULL << scale_bits) * (i >> padding_bits);
  }

  template<typename P>
    __device__ inline void MulInFD(
        TFHEpp::TRLWEInFD<P> &res,
        const TFHEpp::DecomposedPolynomialInFD<P> &a,
        const TFHEpp::TRLWEInFD<P> &b)
    {
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      for (int i = tid; i < P::n / 2; i += bdim) {
#pragma unroll
        for (int m = 0; m < P::k + 1; m++)
        {
          double aimbim = a[i + P::n / 2] * b[m][i + P::n / 2];
          double arebim = a[i] * b[m][i + P::n / 2];
          res[m][i] = fma(a[i], b[m][i], -aimbim);
          res[m][i + P::n / 2] = fma(a[i + P::n / 2], b[m][i], arebim);
        }
      }

      __syncthreads();
    }

  template<typename P>
    __device__ inline void FMAInFD(
        TFHEpp::TRLWEInFD<P> &res,
        const TFHEpp::DecomposedPolynomialInFD<P> &a,
        const TFHEpp::TRLWEInFD<P> &b)
    {
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      for (int i = tid; i < P::n / 2; i += bdim) {
#pragma unroll
        for (int m = 0; m < P::k + 1; m++)
        {
          res[m][i] = fma(a[i], b[m][i], res[m][i]);
          res[m][i] -= a[i + P::n / 2] * b[m][i + P::n / 2];
          res[m][i + P::n / 2] = fma(a[i + P::n / 2], b[m][i], res[m][i + P::n / 2]);
          res[m][i + P::n / 2] = fma(a[i], b[m][i + P::n / 2], res[m][i + P::n / 2]);
        }
      }
      __syncthreads();
    }
} // namespace cuTFHEpp
