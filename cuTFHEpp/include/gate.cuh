#pragma once

#include "types.h"
#include "util/pointer.cuh"

namespace cuTFHEpp
{
  template<typename P>
    __global__ void HomADD_plain(
        TFHEpp::TLWE<P> *res,
        const TFHEpp::TLWE<P> *tlwe,
        const typename P::T value,
        const size_t batch_size)
    {
        const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
        const unsigned int bdim = blockDim.x*blockDim.y;

        for (int i = tid; i < batch_size; i += bdim)
          res[i][P::k * P::n] = tlwe[i][P::k * P::n] + value;
    }

#define CUTFHEPP_HOMADD_PLAIN(X)                    \
  template __global__ void HomADD_plain<Lvl##X>(    \
        TFHEpp::TLWE<Lvl##X> *res,                  \
        const TFHEpp::TLWE<Lvl##X> *tlwe,           \
        const typename Lvl##X::T value,             \
        const size_t batch_size)

  EXPLICIT_LVL_EXTERN(CUTFHEPP_HOMADD_PLAIN);

  template<typename P>
    __global__ void HomADD(
        TFHEpp::TLWE<P> *res,
        const TFHEpp::TLWE<P> *tlwe1,
        const TFHEpp::TLWE<P> *tlwe2,
        const size_t batch_size)
    {
        const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
        const unsigned int bdim = blockDim.x*blockDim.y;

      const unsigned int bid = gridDim.x * blockIdx.y + blockIdx.x;
      const unsigned int gdim = gridDim.x * gridDim.y;

      for (int n = bid; n < batch_size; n += gdim)
        for (int i = tid; i <= P::k * P::n; i += bdim) res[n][i] = tlwe1[n][i] + tlwe2[n][i];
    }

#define CUTFHEPP_HOMADD(X)                         \
  template __global__ void HomADD<Lvl##X>(          \
        TFHEpp::TLWE<Lvl##X> *res,                  \
        const TFHEpp::TLWE<Lvl##X> *tlwe1,          \
        const TFHEpp::TLWE<Lvl##X> *tlwe2,          \
        const size_t batch_size)

  EXPLICIT_LVL_EXTERN(CUTFHEPP_HOMADD);

    template<typename P>
    __global__ void HomSUBLShift(
        TFHEpp::TLWE<P> *res,
        const TFHEpp::TLWE<P> *tlwe1,
        const TFHEpp::TLWE<P> *tlwe2,
        const uint32_t shift_bits,
        const size_t batch_size)
    {
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      const unsigned int bid = gridDim.x * blockIdx.y + blockIdx.x;
      const unsigned int gdim = gridDim.x * gridDim.y;

      for (int n = bid; n < batch_size; n += gdim)
        for (int i = tid; i <= P::k * P::n; i += bdim) res[n][i] = (tlwe1[n][i] - tlwe2[n][i]) << shift_bits;
    }

#define CUTFHEPP_HOMSUBLSHIFT(X)                      \
    template __global__ void HomSUBLShift<Lvl##X>(    \
          TFHEpp::TLWE<Lvl##X> *res,                  \
          const TFHEpp::TLWE<Lvl##X> *tlwe1,          \
          const TFHEpp::TLWE<Lvl##X> *tlwe2,          \
          const uint32_t shift_bits,                  \
          const size_t batch_size)

  EXPLICIT_LVL_EXTERN(CUTFHEPP_HOMSUBLSHIFT);

  template<typename P>
    __global__ void HomSUB(
        TFHEpp::TLWE<P> *res,
        const TFHEpp::TLWE<P> *tlwe1,
        const TFHEpp::TLWE<P> *tlwe2,
        const size_t batch_size)
    {
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      const unsigned int bid = gridDim.x * blockIdx.y + blockIdx.x;
      const unsigned int gdim = gridDim.x * gridDim.y;

      for (int n = bid; n < batch_size; n += gdim)
        for (int i = tid; i <= P::k * P::n; i += bdim) res[n][i] = tlwe1[n][i] - tlwe2[n][i];
    }

#define CUTFHEPP_HOMSUB(X)                          \
  template __global__ void HomSUB<Lvl##X>(          \
        TFHEpp::TLWE<Lvl##X> *res,                  \
        const TFHEpp::TLWE<Lvl##X> *tlwe1,          \
        const TFHEpp::TLWE<Lvl##X> *tlwe2,          \
        const size_t batch_size)

  EXPLICIT_LVL_EXTERN(CUTFHEPP_HOMSUB);

  template<typename P>
    __global__ void HomNOT(
        TFHEpp::TLWE<P> *res,
        const TFHEpp::TLWE<P> *tlwe,
        const size_t batch_size)
    {
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      const unsigned int bid = gridDim.x * blockIdx.y + blockIdx.x;
      const unsigned int gdim = gridDim.x * gridDim.y;

      for (int n = bid; n < batch_size; n += gdim)
        for (int i = tid; i <= P::k * P::n; i += bdim) res[n][i] = -tlwe[n][i];
    }

#define CUTFHEPP_HOMNOT(X)                          \
  template __global__ void HomNOT<Lvl##X>(          \
        TFHEpp::TLWE<Lvl##X> *res,                  \
        const TFHEpp::TLWE<Lvl##X> *tlwe,           \
        const size_t batch_size)

  EXPLICIT_LVL_EXTERN(CUTFHEPP_HOMNOT);

  template<typename P>
    __global__ void HomLShift(
        TFHEpp::TLWE<P> *res,
        const TFHEpp::TLWE<P> *tlwe,
        const uint32_t shift_bits,
        const size_t batch_size)
    {
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      const unsigned int bid = gridDim.x * blockIdx.y + blockIdx.x;
      const unsigned int gdim = gridDim.x * gridDim.y;

      for (int n = bid; n < batch_size; n += gdim)
        for (int i = tid; i <= P::k * P::n; i += bdim) res[n][i] = tlwe[n][i] << shift_bits;
    }

#define CUTFHEPP_HOMLSHIFT(X)                       \
  template __global__ void HomLShift<Lvl##X>(       \
        TFHEpp::TLWE<Lvl##X> *res,                  \
        const TFHEpp::TLWE<Lvl##X> *tlwe,           \
        const uint32_t shift_bits,                  \
        const size_t batch_size)

  EXPLICIT_LVL_EXTERN(CUTFHEPP_HOMLSHIFT);

  template<typename P>
    __global__ void HomCOPY(
        TFHEpp::TLWE<P> *res,
        const TFHEpp::TLWE<P> *tlwe,
        const size_t batch_size)
    {
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      const unsigned int bid = gridDim.x * blockIdx.y + blockIdx.x;
      const unsigned int gdim = gridDim.x * gridDim.y;

      for (int n = bid; n < batch_size; n += gdim)
        for (int i = tid; i <= P::k * P::n; i += bdim) res[n][i] = tlwe[n][i];
    }

#define CUTFHEPP_HOMCOPY(X)                         \
  template __global__ void HomCOPY<Lvl##X>(         \
        TFHEpp::TLWE<Lvl##X> *res,                  \
        const TFHEpp::TLWE<Lvl##X> *tlwe,           \
        const size_t batch_size)

  EXPLICIT_LVL_EXTERN(CUTFHEPP_HOMCOPY);
}
