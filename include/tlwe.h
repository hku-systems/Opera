#pragma once

// This code was modified based on HE3DB: https://github.com/zhouzhangwalker/HE3DB

#include "types.h"

namespace TFHEpp
{
  template <class P>
    TFHEpp::TLWE<P> tlweSymInt32Encrypt(const typename P::T p, const double α, const double scale, const TFHEpp::Key<P> &key)
    {
      std::uniform_int_distribution<typename P::T> Torusdist(0, std::numeric_limits<typename P::T>::max());
      TFHEpp::TLWE<P> res = {};
      res[P::k * P::n] =
        TFHEpp::ModularGaussian<P>(static_cast<typename P::T>(p * scale), α);
      for (int k = 0; k < P::k; k++)
        for (int i = 0; i < P::n; i++) {
          res[k * P::n + i] = Torusdist(generator);
          res[P::k * P::n] += res[k * P::n + i] * key[k * P::n + i];
        }
      return res;
    }

  template <class P>
    typename P::T tlweSymInt32Decrypt(const TFHEpp::TLWE<P> &c, const double scale, const TFHEpp::Key<P> &key)
    {
      typename P::T phase = c[P::k * P::n];
      typename P::T plain_modulus = (1ULL << (std::numeric_limits<typename P::T>::digits -1)) / scale;
      plain_modulus *= 2;
      for (int k = 0; k < P::k; k++)
        for (int i = 0; i < P::n; i++)
          phase -= c[k * P::n + i] * key[k * P::n + i];
      typename P::T res = 
        static_cast<typename P::T>(std::round(phase / scale)) % plain_modulus;
      return res;
    }
} // namespace TFHEpp
