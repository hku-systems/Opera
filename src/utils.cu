#include "utils.h"

// This code was modified based on HE3DB: https://github.com/zhouzhangwalker/HE3DB

namespace opera
{
  void add_scalar(
      const PhantomContext &context,
      PhantomCiphertext &result,
      double scalar,
      PhantomCKKSEncoder &ckks_encoder)
  {
    PhantomPlaintext plain;
    PhantomCiphertext cipher;
    ckks_encoder.encode(context, scalar, result.chain_index(), result.scale(), plain);
    add_plain_inplace(context, result, plain);
  }

  void multiply_scalar(
      const PhantomContext &context,
      PhantomCiphertext &result,
      double scalar,
      double scale,
      PhantomCKKSEncoder &ckks_encoder)
  {
    PhantomPlaintext plain;
    PhantomCiphertext cipher;
    ckks_encoder.encode(context, scalar, result.chain_index(), scale, plain);
    multiply_plain_inplace(context, result, plain);
  }

  void multiply_and_relinearize(
      const PhantomContext &context,
      PhantomCiphertext &cipher1,
      PhantomCiphertext &cipher2,
      PhantomCiphertext &result,
      PhantomRelinKey &relin_keys)
  {
    if (cipher1.coeff_modulus_size_ > cipher2.coeff_modulus_size_)
    {
      mod_switch_to_inplace(context, cipher1, cipher2.chain_index());
    }
    else
    {
      mod_switch_to_inplace(context, cipher2, cipher1.chain_index());
    }
    result = cipher1;
    multiply_inplace(context, result, cipher2);
    relinearize_inplace(context, result, relin_keys);
  }

#if 0
  void pack_encode(
      const PhantomContext &context,
      std::vector<double> &input,
      double scale,
      PhantomPlaintext &plain,
      PhantomCKKSEncoder &ckks_encoder)
  {
    size_t slot_count = ckks_encoder.slot_count();
    size_t input_size = input.size();
    if (input_size <= slot_count)
    {
      int step_size = slot_count / input_size;
      std::vector<double> plain_input(slot_count, 0.);
      for (size_t i = 0; i < slot_count; i++)
      {
        plain_input[i] = input[i % input_size];
      }
      ckks_encoder.encode(context, plain_input, scale, plain);
    }
    else
    {
      throw std::invalid_argument("Out of size.");
    }
  }
#endif

  void pack_encode_param_id(
      const PhantomContext &context,
      std::vector<double> &input,
      size_t chain_index, 
      double scale,
      PhantomPlaintext &plain,
      PhantomCKKSEncoder &ckks_encoder)
  {
    size_t slot_count = ckks_encoder.slot_count();
    size_t input_size = input.size();
    if (input_size <= slot_count)
    {
      // int step_size = slot_count / input_size;
      std::vector<double> plain_input(slot_count, 0.);
      for (size_t i = 0; i < slot_count; i++)
      {
        plain_input[i] = input[i % input_size];
      }
      ckks_encoder.encode(context, plain_input, chain_index, scale, plain);
    }
    else
    {
      throw std::invalid_argument("Out of size.");
    }
  }

  void pack_decode(const PhantomContext &context, std::vector<double> &result, PhantomPlaintext &plain, PhantomCKKSEncoder &ckks_encoder)
  {
    size_t result_size = result.size();
    size_t slot_count = ckks_encoder.slot_count();
    if (result_size <= slot_count)
    {
      // int step_size = slot_count / result_size;
      std::vector<double> plain_output(slot_count, 0.);
      ckks_encoder.decode(context, plain, plain_output);
      for (size_t i = 0; i < result_size; i++)
      {
        result[i] = plain_output[i];
      }
    }
    else
    {
      throw std::invalid_argument("Out of size.");
    }
  }

}
