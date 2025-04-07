#include "repack.h"

// This code was modified based on HE3DB: https://github.com/zhouzhangwalker/HE3DB

namespace opera
{
  void LWEsToRLWEKeyGen(
      const PhantomContext &context,
      LTPreKey &eval_key,
      double scale,
      const PhantomSecretKey &phantom_key,
      const TFHESecretKey &tfhepp_key,
      size_t tfhe_n,
      PhantomCKKSEncoder &encoder)
  {
    size_t slot_count = encoder.slot_count();

    std::vector<double> slots(tfhe_n, 0.);
    for (size_t i = 0; i < tfhe_n; ++i)
    {
      slots[i] = tfhepp_key.key.get<Lvl1>()[i] > 1 ? -1. : static_cast<double>(tfhepp_key.key.get<Lvl1>()[i]);
    }

    PhantomPlaintext plain_sk;
    plain_sk.chain_index() = context.first_context_data().chain_index();
    pack_encode(context, slots, scale, plain_sk, encoder);
    phantom_key.encrypt_symmetric(context, plain_sk, eval_key.key, false);

    size_t g = CeilSqrt(tfhe_n);
    eval_key.rotated_keys.resize(g);
    eval_key.rotated_keys[0] = eval_key.key;

    for (size_t j = 1; j < g; ++j)
    {
      std::rotate(slots.begin(), slots.begin() + 1, slots.end());
      pack_encode(context, slots, scale, plain_sk, encoder);
      phantom_key.encrypt_symmetric(context, plain_sk, eval_key.rotated_keys[j], false);
    }

    // clean up secret material
    memset(slots.data(), 0, sizeof(double) * tfhe_n);
  }

  ChebyshevPoly generate_mod_poly(uint32_t r)
  {
    ChebyshevPoly poly;
    poly.coeff() = sin_coeff;
    double cnst_scale = std::pow(0.5 / M_PI, 1. / (1 << r));
    std::transform(poly.coefficients.begin(), poly.coefficients.end(),
        poly.coefficients.begin(), [&](double u) { return cnst_scale * u; });
    return poly;
  }

  void LinearTransform(
      const PhantomContext &context,
      PhantomCiphertext &result,
      std::vector<std::vector<double>> &matrix,
      double scale,
      LTPreKey &eval_key,
      PhantomCKKSEncoder &encoder,
      PhantomGaloisKey &galois_keys)
  {
    size_t rows = matrix.size();
    size_t columns = matrix.front().size();
    size_t slot_counts = encoder.slot_count();
    if (columns > slot_counts)
    {
      throw std::invalid_argument("Convert LWE ciphers out of size.");
    }

    // BSGS Parameters
    size_t max_len = std::max(rows, columns);
    size_t min_len = std::min(rows, columns);
    size_t g_tilde = CeilSqrt(min_len);
    size_t b_tilde = CeilDiv(min_len, g_tilde);

    // Baby-Step
    if (eval_key.rotated_keys.size() < g_tilde)
    {
      std::cout << "LWEToRLWEKeyGen Error" << std::endl;
      eval_key.rotated_keys.resize(g_tilde);
      eval_key.rotated_keys[0] = eval_key.key;
      for (size_t i = 1; i < g_tilde; i++)
      {
        eval_key.rotated_keys[i - 1] = eval_key.rotated_keys[i];
        rotate_vector_inplace(context, eval_key.rotated_keys[i - 1], 1, galois_keys);
      }
    }

    // Giant-Step
    std::vector<double> diag(max_len);
    PhantomPlaintext plain;
    plain.chain_index() = eval_key.rotated_keys[0].chain_index();
    for (size_t b = 0; b < b_tilde && g_tilde * b < min_len; b++)
    {
      PhantomCiphertext temp, sum;
      for (size_t g = 0; g < g_tilde && b * g_tilde + g < min_len; g++)
      {
        // Get diagonal
        size_t j = b * g_tilde + g;
        for (size_t r = 0; r < max_len; r++)
        {
          diag[r] = matrix[r % rows][(r + j) % columns];
        }
        std::rotate(diag.rbegin(), diag.rbegin() + b * g_tilde, diag.rend());
        pack_encode(context, diag, scale, plain, encoder);
        if (g == 0)
        {
          sum = eval_key.rotated_keys[g];
          multiply_plain_inplace(context, sum, plain);
        }
        else
        {
          temp = eval_key.rotated_keys[g];
          multiply_plain_inplace(context, temp, plain);
          add_inplace(context, sum, temp);
        }
      }
      if (b == 0)
      {
        result = sum;
      }
      else
      {
        rotate_vector_inplace(context, sum, b * g_tilde, galois_keys);
        add_inplace(context, result, sum);
      }
    }

    if (rows < columns)
    {
      size_t gama = std::log2(columns / rows);
      for (size_t j = 0; j < gama; j++)
      {
        PhantomCiphertext temp = result;
        rotate_vector_inplace(context, temp, (1U << j) * rows, galois_keys);
        add_inplace(context, result, temp);
      }
    }
  }

  void HomMod(
      const PhantomContext &context,
      PhantomCiphertext &cipher,
      double scale,
      double q0,
      PhantomCKKSEncoder &encoder,
      PhantomRelinKey &relin_keys)
  {
    uint32_t r = 2;
    //Generate ChebyshevPoly
    ChebyshevPoly poly;
    poly = generate_mod_poly(r);
    uint32_t depth = CeilLog2(poly.degree()) + 1 + r;
    double K = 41;
    // if (cipher.coeff_modulus_size() <= depth + 1)
    // {
    //     throw std::invalid_argument("HomMod: level is small.");
    // }

    auto &context_data = context.get_context_data(cipher.chain_index());
    auto &parms = context_data.parms();

    // printPhantomCiphertext(context, cipher);
    // std::cout << std::fixed << "cipher.scale : " << cipher.scale() << ", q0 :" << q0 << ", scale: " << scale << std::endl;
    double target_scale = cipher.scale() *= std::round(q0 / scale);
    size_t output_level = parms.coeff_modulus().size() - 1 - depth;

    // std::cout << "target_scale1: " << target_scale << std::endl;
    for (size_t i = 1; i <= r; ++i) {
      // std::cout << "output_level: " << output_level << std::endl;
      uint64_t qi =  parms.coeff_modulus()[output_level + i].value(); 
      // std::cout << "target_scale: " << target_scale << ", qi = " << qi << std::endl;
      target_scale *= qi;
      target_scale = std::sqrt(target_scale);
    }
    cipher.scale() = target_scale;

    // std::cout << "target_scale: " << target_scale << std::endl;

    add_scalar(context, cipher, -0.25 / K, encoder);
    PhantomCiphertext cipher_result;
    poly_evaluate_bsgs_lazy(context, cipher_result, target_scale, cipher, poly, encoder, relin_keys);
    if (!phantom::util::are_close(target_scale, cipher_result.scale())) 
    {
      throw std::invalid_argument("HomMod: scale mismatch.");
    }

    double power_r = std::pow(2., r);
    double theta = std::pow(0.5 / M_PI, 1. / power_r);
    cipher = cipher_result;
    for (size_t i = 0; i < r; ++i) {
      theta *= theta;
      multiply_and_relinearize(context,cipher, cipher, cipher, relin_keys);
      add_inplace(context, cipher, cipher);
      add_scalar(context, cipher, 0.-theta, encoder);
      rescale_to_next_inplace(context,cipher);
    }

    cipher.scale() /= std::round(q0 / scale);
  }

  void LWEsToRLWE(
      const PhantomContext &context,
      PhantomCiphertext &result,
      std::vector<TLWELvl1> &lwe_ciphers,
      LTPreKey &eval_key,
      double scale,
      double q0,
      double rescale,
      PhantomCKKSEncoder &encoder,
      PhantomGaloisKey &galois_keys,
      PhantomRelinKey &relin_keys)
  {
    // 1. Preprocess LWE Matrix
    size_t num_lwe_ciphers = lwe_ciphers.size();
    std::vector<std::vector<double>> A(num_lwe_ciphers);
    std::vector<double> b(num_lwe_ciphers);
    double K = 41;
    double multiplier = 1 / K;

    for (size_t i = 0; i < num_lwe_ciphers; i++)
    {
      TLWELvl1 negate_tlwe = lwe_ciphers[i];
      A[i] = std::vector<double>(Lvl1::n);
      // The default ciphertext format in TFHEpp is 
      // Change (a, a*s + m + e) to (-a, a*s + m + e), so the decryption is b + a * s
      for (size_t j = 0; j < Lvl1::k * Lvl1::n; j++)
      {
        negate_tlwe[j] = -negate_tlwe[j];
      }

      std::transform(negate_tlwe.begin(), negate_tlwe.end(), A[i].begin(), 
          [K, rescale](uint32_t value) {return (static_cast<int32_t>(value)) * rescale / K ;});
      b[i] = static_cast<int32_t>(lwe_ciphers[i][Lvl1::n]) * multiplier * rescale;
    }

    // 2. Linear Transform A * s
    LinearTransform(context, result, A, 1.0, eval_key, encoder, galois_keys);
    rescale_to_next_inplace(context, result);
    result.scale() = 1.0;
    // 3. Perform A * s + b
    PhantomPlaintext plain;
    plain.chain_index() = result.chain_index();
    pack_encode_param_id(context, b, result.chain_index(), 1.0, plain, encoder);
    add_plain_inplace(context, result, plain);

    // 4. Perform modular reduction
    result.scale() = scale * rescale;
    HomMod(context, result, scale * rescale, q0 * rescale, encoder, relin_keys);
  }

  void HomRound(
      const PhantomContext &context,
      PhantomCiphertext &cipher,
      double scale,
      PhantomCKKSEncoder &encoder,
      PhantomRelinKey &relin_keys)
  {
    auto &context_data = context.get_context_data(cipher.chain_index());
    auto &parms = context_data.parms();
    auto &coeff_modulus = parms.coeff_modulus();
    // x = 2 * x - 1
    multiply_scalar(context, cipher, 2.0, 1.0, encoder);
    add_scalar(context, cipher, -1.0, encoder);
    poly_evaluate_power(context, cipher, scale, cipher, coeff1, encoder, relin_keys);
    // poly_evaluate_power(cipher, scale, cipher, coeff3, context, encoder, evaluator, relin_keys, decryptor);
    poly_evaluate_power(context, cipher, scale, cipher, coeff5, encoder, relin_keys);
    add_scalar(context, cipher, 0.5, encoder);
  }
}
