#include "polyeval_bsgs.h"

// This code was modified based on HE3DB: https://github.com/zhouzhangwalker/HE3DB

namespace opera
{
  void EvalChebyshevBaisc(
      const PhantomContext &context,
      std::vector<PhantomCiphertext> &T1,
      std::vector<PhantomCiphertext> &T2,
      PhantomCiphertext &x,
      uint64_t degree,
      PhantomCKKSEncoder &encoder,
      PhantomRelinKey &relin_keys)
  {
    //     if (degree < 1)
    //     {
    //       throw std::invalid_argument("EvalChebyshevBaisc: degree is less than 1.");
    //     }
    uint64_t m = CeilLog2(degree + 1);
    uint64_t l = m / 2;
    T1.resize((1ULL << l) - 1);

    //Evaluate T_{1}, T_{2}, T_{3}, ..., T_{2^l - 1}
    T1[0] = x;
    for (size_t i = 2; i < (1ULL << l); i++)
    {
      // T_{i = a + b} = 2 * T_{a} * T_{b} - T_{|a - b|} 
      uint64_t a = (i + 1) / 2;
      uint64_t b = i - a;
      uint64_t c = a > b ? a - b : b - a;
      multiply_and_relinearize(context, T1[a - 1], T1[b - 1], T1[i - 1], relin_keys);

      add_inplace(context, T1[i - 1], T1[i - 1]);
      if (c == 0)
      {
        // T_{i = a + b} = 2 * T_{a} * T_{b} - T_{0} 
        add_scalar(context, T1[i - 1], -1., encoder);

        rescale_to_next_inplace(context, T1[i - 1]);

      }
      else
      {
        // T_{i = a + b} = 2 * T_{a} * T_{b} - T_{1} 
        PhantomCiphertext temp = T1[0];
        multiply_scalar(context, temp, 1., T1[i -1].scale() / T1[0].scale(), encoder);

        mod_switch_to_inplace(context, temp, T1[i-1].chain_index());

        sub_inplace(context, T1[i-1], temp);

        rescale_to_next_inplace(context, T1[i-1]);

      }

    }
    // Evaluate T_{2^l}, T_{2^{l+1}}, ..., T_{2^{m-1}}
    T2.resize(m - l);
    PhantomCiphertext temp;
    temp = T1[(1ULL << (l -1 )) - 1];
    mod_switch_to_inplace(context, temp, T1[(1ULL << l) - 2].chain_index());
    for (size_t i = 0; i < m - l; i++)
    {
      multiply_and_relinearize(context, temp, temp, T2[i], relin_keys);
      add_inplace(context, T2[i], T2[i]);
      add_scalar(context, T2[i], -1., encoder);
      rescale_to_next_inplace(context, T2[i]);
      temp = T2[i];
    }
  }

  void DivisionChebyshevLazy(ChebyshevPoly &f, uint64_t ChebyshevDegree, ChebyshevPoly &quotient, ChebyshevPoly &remainder)
  {
    if (f.degree() < ChebyshevDegree)
    {
      quotient = ChebyshevPoly();
      quotient.coefficients.resize(1, 0.);
      remainder = f;
    }
    else
    {
      remainder = ChebyshevPoly(ChebyshevDegree - 1);
      std::copy_n(f.coefficients.data(), ChebyshevDegree, remainder.coefficients.data());
      quotient = ChebyshevPoly(f.degree() - ChebyshevDegree);
      quotient.coefficients[0] = f.coefficients[ChebyshevDegree];

      for (size_t i = ChebyshevDegree + 1, j = 1; i <= f.degree(); i++, j++)
      {
        quotient.coefficients[i - ChebyshevDegree] = 2 * f.coefficients[i];
        remainder.coefficients[ChebyshevDegree - j] -= f.coefficients[i];
      }
    }
  }

  // Lazy Algotirhm 2 in Jean-Philippe Bossuat et al's paper which does not use level optimization
  void EvalRecurseLazy(
      const PhantomContext &context,
      double target_scale,
      uint64_t m,
      uint64_t l,
      ChebyshevPoly &poly,
      std::vector<PhantomCiphertext> &T1,
      std::vector<PhantomCiphertext> &T2,
      PhantomCiphertext &result,
      PhantomCKKSEncoder &encoder,
      PhantomRelinKey &relin_keys)
  {
    if (poly.degree() < 0)
    {
      result.free();
      return ;
    }
    uint64_t d = poly.degree();
    if (d < (1ULL << l))
    {
      if (d == 0)
      {
        if (std::abs(std::round(poly.coefficients[0] * target_scale)) > 1.)
        {
          result.free();
          result.resize(context, T1[0].chain_index(), 2);
          result.scale() = target_scale;
          result.is_ntt_form() = true;
          result.correction_factor() = 1;
          result.SetNoiseScaleDeg(1);
          add_scalar(context, result, poly.coefficients[0], encoder);

        }
        else
        {
          result.free();
        }
        return ;
      }

      // Evaluate Polynomial
      // result = \sum_{i=0}^{d} poly[i]*Enc(T_{i}(x))
      auto &context_data = context.get_context_data(T1[d -1].chain_index());
      auto &parms = context_data.parms();
      double qT_d = parms.coeff_modulus()[T1[d-1].coeff_modulus_size_ - 1].value();
      double cipher_scale = target_scale * qT_d;
      PhantomCiphertext temp;
      bool all_zero = true;
      // line 5 of Algorithm 2.
      result.free();
      result.resize(context, T1[d - 1].chain_index(), 2, true);
      result.scale() = cipher_scale;
      result.is_ntt_form() = true;
      result.correction_factor() = 1;
      result.SetNoiseScaleDeg(1);
      // line 6 ~line 8 of Algorithm 2 .
      for (size_t i = d; i > 0; i--)
      {
        if (std::abs(std::round(poly.coefficients[i] * target_scale)) > 1.)
        {
          temp = T1[i - 1];
          mod_switch_to_inplace(context, temp, T1[d-1].chain_index());
          multiply_scalar(context, temp, poly.coefficients[i], cipher_scale / T1[i-1].scale(), encoder);
          add_inplace(context, result, temp);

          all_zero = false;
        }
      }

      // line 5 of Algorithm
      if (std::abs(std::round(poly.coefficients[0] * target_scale)) > 1.)
      {
        add_scalar(context, result, poly.coefficients[0], encoder);

        all_zero = false;
      }


      if (all_zero)
      {
        result.free();
        return ;
      }
      else
      {
        rescale_to_next_inplace(context, result);

        return ;
      }
    }
    // The const multiplication will consume 1 level.

    uint64_t ChebyshevDegree = 1ULL << (m -1);
    uint64_t ChebyshevIndex = m - 1 - l;
    ChebyshevPoly quotient, remainder;
    DivisionChebyshevLazy(poly, ChebyshevDegree, quotient, remainder);

    size_t level = T2[ChebyshevIndex].coeff_modulus_size_ - 1;
    auto &context_data = context.get_context_data(context.get_first_index());
    auto &parms = context_data.parms();
    double q = parms.coeff_modulus()[level].value();
    double quotient_scale = target_scale * q / T2[ChebyshevIndex].scale();

    PhantomCiphertext cipher_quotient, cipher_remainder;
    EvalRecurseLazy(context, target_scale, m -1, l, remainder, T1, T2, cipher_remainder, encoder, relin_keys);
    EvalRecurseLazy(context, quotient_scale, m - 1, l , quotient, T1, T2, cipher_quotient, encoder, relin_keys);

    if (cipher_quotient.size() && cipher_remainder.size())
    {
      // Both q(x) and r(x) are not zero
      multiply_and_relinearize(context, cipher_quotient, T2[ChebyshevIndex], result, relin_keys);

      if (result.coeff_modulus_size_ <= cipher_remainder.coeff_modulus_size_)
      {
        multiply_scalar(context, cipher_remainder, 1., result.scale() / cipher_remainder.scale(), encoder);
        mod_switch_to_inplace(context, cipher_remainder, result.chain_index());
        add_inplace(context, result, cipher_remainder);
        rescale_to_next_inplace(context, result);

      }
      else
      {
        rescale_to_next_inplace(context, result);

        if (!phantom::util::are_close(result.scale(), cipher_remainder.scale())) 
        {
          result.scale() = cipher_remainder.scale();
        }
        mod_switch_to_inplace(context, result, cipher_remainder.chain_index());

        add_inplace(context, result, cipher_remainder);

      }
    }
    else
    {
      if (cipher_quotient.size())
      {
        // If q(x) are not zero
        multiply_and_relinearize(context, cipher_quotient, T2[ChebyshevIndex], result, relin_keys);
        rescale_to_next_inplace(context, result);

      }
      else if (cipher_remainder.size())
      {
        // If r(x) are not zero
        result = cipher_remainder;
      }
      else
      {
        // If q(x) and r(x) are zero
        result.free();
      }
    }
    return ;

  }

  void poly_evaluate_bsgs_lazy(
      const PhantomContext &context,
      PhantomCiphertext &result,
      double target_scale,
      PhantomCiphertext &x,
      ChebyshevPoly &poly,
      PhantomCKKSEncoder &encoder,
      PhantomRelinKey &relin_keys)
  {
    uint64_t degree = poly.degree();
    uint64_t m = CeilLog2(degree + 1);
    uint64_t l = m / 2;
    std::vector<PhantomCiphertext> T1,T2;
    EvalChebyshevBaisc(context, T1, T2, x, degree, encoder, relin_keys);
    EvalRecurseLazy(context, target_scale, m, l, poly, T1, T2, result, encoder, relin_keys);
  }

  void EvalPower(
      const PhantomContext &context,
      double target_scale,
      std::vector<double> coefficients,
      std::vector<PhantomCiphertext> &power_basis,
      PhantomCiphertext &result,
      PhantomCKKSEncoder &encoder,
      PhantomRelinKey &relin_keys)
  {
    if (coefficients.size() == 1)
    {
      if (std::abs(std::round(coefficients[0] * target_scale)) > 1.)
      {
        auto &context_data = context.get_context_data(power_basis[0].chain_index());
        auto &parms = context_data.parms();
        double qT_d = parms.coeff_modulus()[power_basis[0].coeff_modulus_size_ - 1].value();
        double cipher_scale = target_scale * qT_d;
        result = power_basis[0];
        multiply_scalar(context, result, coefficients[0], cipher_scale / power_basis[0].scale(), encoder);
        rescale_to_next_inplace(context, result);
        return ;
      }
      else
      {
        result.free();
        return ;
      }
    }
    std::vector<double> quotient, remainder;
    uint64_t degree = 2 * coefficients.size() - 1;
    uint64_t m = CeilLog2(degree + 1);
    remainder.resize((1 << (m-1)) / 2);
    quotient.resize(coefficients.size() - remainder.size());
    for (size_t i = 0; i < remainder.size(); i++)
    {
      remainder[i] = coefficients[i];
    }
    for (size_t i = 0; i < quotient.size(); i++)
    {
      quotient[i] = coefficients[i + remainder.size()]; 
    }

    auto &context_data = context.get_context_data(power_basis[m-1].chain_index());
    auto &parms = context_data.parms();
    double qT_d = parms.coeff_modulus()[power_basis[m-1].coeff_modulus_size_ - 1].value();
    PhantomCiphertext cipher_quotient, cipher_remainder;
    double quotient_scale = target_scale * qT_d / power_basis[m-1].scale();
    double remainder_scale = target_scale;
    EvalPower(context, quotient_scale, quotient, power_basis, cipher_quotient, encoder, relin_keys);
    EvalPower(context, remainder_scale, remainder, power_basis, cipher_remainder, encoder, relin_keys);
    multiply_and_relinearize(context, cipher_quotient, power_basis[m-1], result, relin_keys);
    rescale_to_next_inplace(context, result);
    // seal::Plaintext plain;
    // std::vector<double> computed;
    // decryptor.decrypt(result, plain);
    // encoder.decode(plain, computed);
    // for (size_t i = 0; i < 9; i++)
    // {
    //     std::cout << "Computed1: " << computed[i] << std::endl;
    // }
    mod_switch_to_inplace(context, cipher_remainder, result.chain_index());
    // decryptor.decrypt(cipher_remainder, plain);
    // encoder.decode(plain, computed);
    // for (size_t i = 0; i < 9; i++)
    // {
    //     std::cout << "Computed2: " << computed[i] << std::endl;
    // }
    cipher_remainder.scale() = result.scale();
    add_inplace(context, result, cipher_remainder);

    return ;
  }

  // Evaluate polynomial in a power basis, in the form of a_1 x + a_3 x ^ 3 + a_5 x ^ 5 + a_7 x ^ 7 + ...
  void poly_evaluate_power(
      const PhantomContext &context,
      PhantomCiphertext &result,
      double target_scale,
      PhantomCiphertext &x,
      std::vector<double> &coefficients,
      PhantomCKKSEncoder &encoder,
      PhantomRelinKey &relin_keys)
  {
    uint64_t degree = coefficients.size() * 2 - 1;
    uint64_t m = CeilLog2(degree + 1);
    std::vector<PhantomCiphertext> power_basis(m);
    power_basis[0] = x;
    for (size_t i = 1; i < m; i++)
    {
      multiply_and_relinearize(context, power_basis[i-1], power_basis[i-1], power_basis[i], relin_keys);
      rescale_to_next_inplace(context, power_basis[i]);
    }

    EvalPower(context, target_scale, coefficients, power_basis, result, encoder, relin_keys);
  }
}
