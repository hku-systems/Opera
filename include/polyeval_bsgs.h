#pragma once

// This code was modified based on HE3DB: https://github.com/zhouzhangwalker/HE3DB

#include <phantom.h>
#include "utils.h"

namespace opera
{
  typedef struct ChebyshevPoly
  {
    ChebyshevPoly() {}

    explicit ChebyshevPoly(size_t degree)
    {
      coefficients.resize(degree + 1, 0.);
    }

    uint64_t degree()
    {
      return coefficients.empty() ? -1 : coefficients.size() - 1;
    }

    std::vector<double> &coeff()
    {
      return coefficients;
    }

    std::vector<double> coefficients;
  } ChebyshevPoly;

  void poly_evaluate_bsgs_lazy(const PhantomContext &context, PhantomCiphertext &result,
      double target_scale, PhantomCiphertext &x, ChebyshevPoly &poly,
      PhantomCKKSEncoder &encoder, PhantomRelinKey &relin_keys);

  // Evaluate polynomial in a power basis, in the form of a_1 x + a_3 x ^ 3 + a_5 x ^ 5 + a_7 x ^ 7 + ...
  void poly_evaluate_power(const PhantomContext &context, PhantomCiphertext &result,
      double target_scale, PhantomCiphertext &x, std::vector<double> &coefficients,
      PhantomCKKSEncoder &encoder, PhantomRelinKey &relin_keys);
}
