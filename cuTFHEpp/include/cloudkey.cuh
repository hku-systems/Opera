#pragma once

#include "utils.cuh"

namespace cuTFHEpp
{
  template<typename P>
    struct cuBootstrappingKeyFFT
    {
      TFHEpp::BootstrappingKeyFFT<P> *bkfft_ = nullptr;

      cuBootstrappingKeyFFT() = delete;

      cuBootstrappingKeyFFT(TFHEpp::BootstrappingKeyFFT<P> *bkfft)
      {
        if (bkfft)
        {
          CUDA_CHECK_RETURN(cudaMalloc(&bkfft_, sizeof(TFHEpp::BootstrappingKeyFFT<P>)));
          CUDA_CHECK_RETURN(cudaMemcpy(bkfft_, bkfft, sizeof(TFHEpp::BootstrappingKeyFFT<P>), cudaMemcpyHostToDevice));
        }
      }

      ~cuBootstrappingKeyFFT()
      {
        if (bkfft_) CUDA_CHECK_RETURN(cudaFree(bkfft_));
        bkfft_ = nullptr;
      }

      cuBootstrappingKeyFFT(const cuBootstrappingKeyFFT &) = delete;
      cuBootstrappingKeyFFT &operator=(const cuBootstrappingKeyFFT &) = delete;
      cuBootstrappingKeyFFT &operator=(cuBootstrappingKeyFFT &&) = delete;
      cuBootstrappingKeyFFT(cuBootstrappingKeyFFT &&) = delete;

      __host__ __device__ inline TFHEpp::BootstrappingKeyFFT<P> *get() const { return bkfft_; }
    };

  template<typename P>
    struct cuKeySwitchingKey
    {
      TFHEpp::KeySwitchingKey<P> *ksk_ = nullptr;

      cuKeySwitchingKey() = delete;
      cuKeySwitchingKey(TFHEpp::KeySwitchingKey<P> *ksk)
      {
        if (ksk)
        {
          CUDA_CHECK_RETURN(cudaMalloc(&ksk_, sizeof(TFHEpp::KeySwitchingKey<P>)));
          CUDA_CHECK_RETURN(cudaMemcpy(ksk_, ksk, sizeof(TFHEpp::KeySwitchingKey<P>), cudaMemcpyHostToDevice));
        }
      }

      ~cuKeySwitchingKey()
      {
        if (ksk_) CUDA_CHECK_RETURN(cudaFree(ksk_));
        ksk_ = nullptr;
      }

      cuKeySwitchingKey(const cuKeySwitchingKey &) = delete;
      cuKeySwitchingKey &operator=(const cuKeySwitchingKey &) = delete;
      cuKeySwitchingKey &operator=(cuKeySwitchingKey &&) = delete;
      cuKeySwitchingKey(cuKeySwitchingKey &&) = delete;

      __host__ __device__ inline TFHEpp::KeySwitchingKey<P> *get() const { return ksk_; }
    };
} // namespace cuTFHEpp
