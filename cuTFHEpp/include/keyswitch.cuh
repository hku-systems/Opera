#pragma once

#include "context.cuh"
#include "types.h"

namespace cuTFHEpp
{
  template<typename LvlXY, typename LvlX = LvlXY::domainP, typename LvlY = LvlXY::targetP>
    __device__ inline void IdentityKeySwitch(
        TFHEpp::TLWE<LvlY> &res,
        TFHEpp::TLWE<LvlX> &tlwe,
        const TFHEpp::KeySwitchingKey<LvlXY> &ksk)
    {
      constexpr typename LvlX::T prec_offset =
        1ULL << (std::numeric_limits<typename LvlX::T>::digits -
            (1 + LvlXY::basebit * LvlXY::t));

      constexpr uint32_t mask = (1U << LvlXY::basebit) - 1;

      constexpr uint32_t domain_digit =
        std::numeric_limits<typename LvlX::T>::digits;
      constexpr uint32_t target_digit =
        std::numeric_limits<typename LvlY::T>::digits;

      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      for (int i = tid; i <= LvlY::k * LvlY::n; i += bdim)
      {
        res[i] = 0;

        if (i == LvlY::k * LvlY::n)
        {
          if constexpr (domain_digit == target_digit)
            res[i] = tlwe[LvlX::k * LvlX::n];
          else if constexpr (domain_digit > target_digit)
            res[i] = (tlwe[LvlX::k * LvlX::n] +
                (1ULL << (domain_digit - target_digit - 1))) >>
              (domain_digit - target_digit);
          else if constexpr (domain_digit < target_digit)
            res[i] = tlwe[LvlX::k * LvlX::n]
              << (target_digit - domain_digit);
        }

        for (int j = 0; j < LvlX::k * LvlX::n; j++)
        {
          const typename LvlX::T aibar = tlwe[j] + prec_offset;

#pragma unroll
          for (int k = 0; k < LvlXY::t; k++)
          {
            const uint32_t aij = (aibar >> (std::numeric_limits<typename LvlX::T>::digits - (k + 1) * LvlXY::basebit)) & mask;
            if (aij != 0)
              res[i] -= ksk[j][k][aij - 1][i];
          }
        }
      }
    }

  template<typename LvlXY, typename LvlX = LvlXY::domainP, typename LvlY = LvlXY::targetP>
    __global__ void IdentityKeySwitch(
        const Context &ctx,
        TFHEpp::TLWE<LvlY> *res,
        TFHEpp::TLWE<LvlX> *tlwe,
        const size_t batch_size)
    {
      const unsigned int bid = gridDim.x * blockIdx.y + blockIdx.x;
      const unsigned int gdim = gridDim.x * gridDim.y;

      TFHEpp::KeySwitchingKey<LvlXY> &ksk = *ctx.get_ksk<LvlXY>();

      for (int n = bid; n < batch_size; n += gdim)
        IdentityKeySwitch<LvlXY>(res[n], tlwe[n], ksk);
    }

#define CUTFHEPP_KEY_SWITCH(X, Y)                         \
  template __global__ void IdentityKeySwitch<Lvl##X##Y>(  \
      const Context &ctx,                                 \
      TFHEpp::TLWE<Lvl##Y> *res,                          \
      TFHEpp::TLWE<Lvl##X> *tlwe,                         \
      const size_t batch_size);

  EXPLICIT_LVL_DOWN_EXTERN(CUTFHEPP_KEY_SWITCH);
} // namespace cuTFHEpp
