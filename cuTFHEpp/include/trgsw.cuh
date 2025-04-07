#pragma once

#include "context.cuh"

namespace cuTFHEpp
{
  template <class P>
    constexpr typename P::T offsetgen()
    {
      typename P::T offset = 0;
      for (int i = 1; i <= P::l; i++)
        offset +=
          P::Bg / 2 *
          (1ULL << (std::numeric_limits<typename P::T>::digits - i * P::Bgbit));
      return offset;
    }

  template<typename P>
    __device__ inline void PolynomialMulByXai(
      TFHEpp::Polynomial<P> &res,
      TFHEpp::Polynomial<P> &testvector,
      const uint32_t a)
    {
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      for (int i = tid; i < P::n; i += bdim)
      {
        if (a == 0) res[i] = testvector[i];
        else if (a < P::n) res[i] = (i < a) ? -testvector[i - a + P::n] : testvector[i - a];
        else res[i] = (i < (a - P::n)) ? testvector[i - a + 2*P::n] : -testvector[i - a + P::n];
      }
    }

  template<typename P>
    __device__ inline void PolynomialMulByXaiMinusOne(
        TFHEpp::Polynomial<P> &res,
        const TFHEpp::Polynomial<P> &poly,
        const uint32_t a)
    {
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      constexpr typename P::T offset = offsetgen<P>();
      constexpr typename P::T roundoffset =
        1ULL << (std::numeric_limits<typename P::T>::digits - P::l * P::Bgbit -
            1);
      constexpr typename P::T mask =
        static_cast<typename P::T>((1ULL << P::Bgbit) - 1);
      constexpr typename P::T halfBg = (1ULL << (P::Bgbit - 1));

      for (int i = tid; i < P::n; i += bdim)
      {
        if (a < P::n) res[i] = (i < a) ? -poly[i - a + P::n] : poly[i - a];
        else res[i] = (i < (a - P::n)) ? poly[i - a + 2*P::n] : -poly[i - a + P::n];
        res[i] -= poly[i];
      }
    }

  template<typename P>
    __device__ inline void DecompositionPolynomial(
        TFHEpp::DecomposedPolynomial<P> &decpoly,
        const TFHEpp::Polynomial<P> &poly,
        const int digit)
    {
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      constexpr typename P::T offset = offsetgen<P>();
      constexpr typename P::T roundoffset =
        1ULL << (std::numeric_limits<typename P::T>::digits - P::l * P::Bgbit - 1);
      constexpr typename P::T mask =
        static_cast<typename P::T>((1ULL << P::Bgbit) - 1);
      constexpr typename P::T halfBg = (1ULL << (P::Bgbit - 1));

      for (int i = tid; i < P::n; i += bdim)
        decpoly[i] = (((poly[i] + offset + roundoffset) >>
              (std::numeric_limits<typename P::T>::digits -
               (digit + 1) * P::Bgbit)) & mask) - halfBg;
    }

  template<typename P>
    __device__ inline void DecompositionPolynomial(
        TFHEpp::DecomposedPolynomialInFD<P> &decpolyfft,
        const TFHEpp::Polynomial<P> &poly,
        const int digit)
    {
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      constexpr typename P::T offset = offsetgen<P>();
      constexpr typename P::T roundoffset =
        1ULL << (std::numeric_limits<typename P::T>::digits - P::l * P::Bgbit - 1);
      constexpr typename P::T mask =
        static_cast<typename P::T>((1ULL << P::Bgbit) - 1);
      constexpr typename P::T halfBg = (1ULL << (P::Bgbit - 1));

      for (int i = tid; i < P::n; i += bdim)
        decpolyfft[i] = static_cast<double>(static_cast<typename std::make_signed<typename P::T>::type>(
            (((poly[i] + offset + roundoffset) >>
              (std::numeric_limits<typename P::T>::digits -
               (digit + 1) * P::Bgbit)) & mask) - halfBg));
    }

  template<typename P>
    __device__ inline void DecompositionPolynomialFFT(
        const Context &context,
        TFHEpp::DecomposedPolynomialInFD<P> &decpolyfft,
        const TFHEpp::Polynomial<P> &poly,
        const int digit)
    {
      DecompositionPolynomial<P>(decpolyfft, poly, digit);
      __syncthreads();
      TwistIFFT_inplace<P>(context.get_fft_data<P>(), decpolyfft);
    }

  template<typename P>
    __device__ inline void trgswfftExternalProduct(
        const Context &context,
        double *shared_mem,
        TFHEpp::TRLWE<P> &temp,
        TFHEpp::TRLWEInFD<P> &trlwefft,
        TFHEpp::TRGSWFFT<P> &trgswfft,
        const uint32_t a)
    {
      TFHEpp::DecomposedPolynomialInFD<P> *decpolyfft = reinterpret_cast<TFHEpp::DecomposedPolynomialInFD<P> *>(shared_mem);
      DecompositionPolynomialFFT<P>(context, *decpolyfft, temp[0], 0);
      MulInFD<P>(trlwefft, *decpolyfft, trgswfft[0]);

#pragma unroll
      for (int i = 1; i < P::l; i++)
      {
        DecompositionPolynomialFFT<P>(context, *decpolyfft, temp[0], i);
        FMAInFD<P>(trlwefft, *decpolyfft, trgswfft[i]);
      }

#pragma unroll
      for (int k = 1; k < P::k + 1; k++)
      {
#pragma unroll
        for (int i = 0; i < P::l; i++)
        {
          DecompositionPolynomialFFT<P>(context, *decpolyfft, temp[k], i);
          FMAInFD<P>(trlwefft, *decpolyfft, trgswfft[i + k * P::l]);
        }
      }

#pragma unroll
      for (int k = 0; k < P::k + 1; k++)
        TwistFFT<P>(context.get_fft_data<P>(), temp[k], trlwefft[k], *decpolyfft);
    }
} // namespace cuTFHEpp
