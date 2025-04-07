#pragma once

// This code was modified based on HE3DB: https://github.com/zhouzhangwalker/HE3DB

#include <phantom.h>

#define LOGIC true
#define ARITHMETIC false
#define ASCENDING 1
#define DESCENDING 0
#define MINIMUM 1
#define MAXIMUM 0
#define IS_LOGIC(a) a
#define IS_ARITHMETIC(a) !a

#define EXPLICIT_LVL_LOG_ARI_DEFINE(P)    \
  P(1,LOGIC);                             \
  P(1,ARITHMETIC);                        \
  P(2,LOGIC);                             \
  P(2,ARITHMETIC);
#define EXPLICIT_LVL_LOG_ARI_EXTERN(P)    \
  extern P(1,LOGIC);                      \
  extern P(1,ARITHMETIC);                 \
  extern P(2,LOGIC);                      \
  extern P(2,ARITHMETIC);

namespace opera
{
  template <typename T>
    inline uint64_t CeilLog2(T x)
    {
      return static_cast<uint64_t>(std::ceil(std::log2(x)));
    }

  template <typename T>
    static inline T CeilDiv(T a, T b) 
    {
      return (a + b - 1) / b;
    }

  template <typename T>
    static inline T CeilSqrt(T val) 
    {
      return static_cast<T>(std::ceil(std::sqrt(1. * val)));
    }

  template <class T, class A>
  void pack_encode(
      const PhantomContext &context,
      std::vector<T, A> &input,
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
        plain_input[i] = (double)input[i % input_size];
      }
      ckks_encoder.encode(context, plain_input, scale, plain);
    }
    else
    {
      throw std::invalid_argument("Out of size.");
    }
  }


  void add_scalar(const PhantomContext &context, PhantomCiphertext &result,
      double scalar, PhantomCKKSEncoder &ckks_encoder);

  void multiply_scalar(const PhantomContext &context, PhantomCiphertext &result,
      double scalar, double scale, PhantomCKKSEncoder &ckks_encoder);

  void multiply_and_relinearize(const PhantomContext &context, PhantomCiphertext &cipher1,
      PhantomCiphertext &cipher2, PhantomCiphertext &result, PhantomRelinKey &relin_keys);

  // void pack_encode(const PhantomContext &context, std::vector<double> &input,
  //     double scale, PhantomPlaintext &plain, PhantomCKKSEncoder &ckks_encoder);

  void pack_encode_param_id(const PhantomContext &context, std::vector<double> &input,
      size_t chain_index, double scale, PhantomPlaintext &plain,
      PhantomCKKSEncoder &ckks_encoder);

  void pack_decode(const PhantomContext &context, std::vector<double> &result,
      PhantomPlaintext &plain, PhantomCKKSEncoder &ckks_encoder);
}
