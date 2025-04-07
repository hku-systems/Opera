#pragma once

#include "types.h"
#include "cloudkey.cuh"
#include "utils.cuh"
#include "fft.cuh"

namespace cuTFHEpp
{
  struct Context
  {
    const FFTData<Lvl1> fft_lvl1_;
    const FFTData<Lvl2> fft_lvl2_;
    const cuBootstrappingKeyFFT<Lvl01> bkfftlvl01_;
    const cuBootstrappingKeyFFT<Lvl02> bkfftlvl02_;
    const cuKeySwitchingKey<Lvl10> ksk10_;
    const cuKeySwitchingKey<Lvl20> ksk20_;
    const cuKeySwitchingKey<Lvl21> ksk21_;

    Context() :
      fft_lvl1_(), fft_lvl2_(),
      bkfftlvl01_(nullptr), bkfftlvl02_(nullptr),
      ksk10_(nullptr), ksk20_(nullptr), ksk21_(nullptr) {}

    Context(const TFHEEvalKey &ek) :
      fft_lvl1_(), fft_lvl2_(),
      bkfftlvl01_(ek.bkfftlvl01.get()), bkfftlvl02_(ek.bkfftlvl02.get()),
      ksk10_(ek.iksklvl10.get()), ksk20_(ek.iksklvl20.get()), ksk21_(ek.iksklvl21.get()) {}


    template<typename P>
      __host__ __device__ inline const FFTData<P> &get_fft_data() const
      {
        if constexpr(std::is_same<P,Lvl1>::value)
          return fft_lvl1_;
        else if constexpr(std::is_same<P,Lvl2>::value)
          return fft_lvl2_;
        else static_assert(TFHEpp::false_v<P>, "Undefined Type for get_fft_data");
      }

    template<typename P>
      __host__ __device__ inline TFHEpp::BootstrappingKeyFFT<P> *get_bk() const
      {
        if constexpr (std::is_same_v<P, Lvl01>)
          return bkfftlvl01_.get();
        else if constexpr (std::is_same_v<P, Lvl02>)
          return bkfftlvl02_.get();
        else
          static_assert(TFHEpp::false_v<P>, "Undefined BootstrappingKey");
      }

    template<typename P>
      __host__ __device__ inline TFHEpp::KeySwitchingKey<P> *get_ksk() const
      {
        if constexpr (std::is_same_v<P, Lvl10>)
          return ksk10_.get();
        else if constexpr (std::is_same_v<P, Lvl20>)
          return ksk20_.get();
        else if constexpr (std::is_same_v<P, Lvl21>)
          return ksk21_.get();
        else
          static_assert(TFHEpp::false_v<P>, "Undefined KeySwitchingKey");
      }
  };
} // namespace cuTFHEpp
