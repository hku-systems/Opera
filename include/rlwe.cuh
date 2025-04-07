#pragma once

#include <sstream>
#include <memory>
#include <phantom.h>
#include "repack.h"

namespace opera
{

class PhantomRLWE {
 public:
  const uint64_t scale_bits = 29;
  const uint64_t modq_bits = 32;
  const uint64_t modulus_bits = 45;
  const uint64_t repack_scale_bits = modulus_bits + scale_bits - modq_bits;
  const size_t poly_modulus_degree = 65536;
  const double scale = std::pow(2.0, scale_bits);

  std::shared_ptr<PhantomContext> context;
  std::shared_ptr<PhantomSecretKey> secret_key;
  std::shared_ptr<PhantomRelinKey> relin_keys;
  std::shared_ptr<PhantomGaloisKey> galois_keys;
  std::shared_ptr<PhantomCKKSEncoder> ckks_encoder;

  phantom::EncryptionParameters parms;
  size_t _rows;
  std::vector<int> _coeff_modulus_bit_size;
  std::stringbuf buffer;
  bool is_buffered = false;

  inline std::vector<int> find_galois_steps(size_t row, bool aggr_step = false) {
    std::set<size_t> steps;
    if (aggr_step) {
      size_t log_slots = ceil(log2(row));
      // Specify the rotations you want
      for (size_t j = 1; j < (1 << log_slots); j <<= 1) {
        steps.insert(j);
      }
    } else {
      steps.insert(1);
      size_t min_len = std::min(row, (size_t)Lvl1::n);
      size_t g_tilde = CeilSqrt(min_len);
      size_t b_tilde = CeilDiv(min_len, g_tilde);
      for (size_t b = 1; b < b_tilde && g_tilde * b < min_len; ++b) {
        steps.insert(b * g_tilde);
      }
      if (row < (size_t)Lvl1::n) {
        size_t gama = std::log2((size_t)Lvl1::n / row);
        for (size_t j = 0; j < gama; j++) {
          steps.insert((1U << j) * row);
        }
      }
    }
    return std::vector<int>(steps.begin(), steps.end());
  }

  phantom::EncryptionParameters generateCKKSParms() {
    std::cout << "Generating Parameters..." << std::endl;
    phantom::EncryptionParameters parms(phantom::scheme_type::ckks);
    size_t poly_modulus_degree = 65536;
    parms.set_poly_modulus_degree(poly_modulus_degree);
    auto coeff_modulus = phantom::CoeffModulus::Create(
      poly_modulus_degree, _coeff_modulus_bit_size);

    parms.set_coeff_modulus(coeff_modulus);
    std::vector<int> galois_steps = find_galois_steps(_rows);
    parms.set_galois_elts(
        get_elts_from_steps(galois_steps, poly_modulus_degree));
    return std::move(parms);
  }


  PhantomRLWE(size_t rows, std::vector<int> coeff_modulus_bit_size) :
    _rows(rows), _coeff_modulus_bit_size(coeff_modulus_bit_size)
  {
    parms = generateCKKSParms();
    context = std::make_shared<PhantomContext>(parms);
    secret_key = std::make_shared<PhantomSecretKey>(parms);
    secret_key->gen_secretkey(*context);
    relin_keys = std::make_shared<PhantomRelinKey>(*context);
    secret_key->gen_relinkey(*context, *relin_keys);
    // galois_keys = new PhantomGaloisKey(*context);
    // secret_key->create_galois_keys(*context, *galois_keys);
    ckks_encoder = std::make_shared<PhantomCKKSEncoder>(*context);
    galois_keys = nullptr;
  }

  PhantomRLWE(size_t rows) :
    PhantomRLWE(rows, std::vector<int>{
      59, 42, 42, 42, 42, 42, 42, 42, 45, 45, 45, 45, 45,
      45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 59}) {}

  void genLWE2RLWEGaloisKeys() {
    std::cout << "Generating LWE2RLWE Galois Keys..." << std::endl;
    std::vector<int> galois_steps = find_galois_steps(_rows, false);
    context->set_galois_elts(
        get_elts_from_steps(galois_steps, parms.poly_modulus_degree()));
    galois_keys = std::make_shared<PhantomGaloisKey>(*context);
    secret_key->create_galois_keys(*context, *galois_keys);
    std::cout << "Number:" << galois_steps.size() << std::endl;
  }
  // set_galois_elts
  void genGaloisKeys() {
    std::cout << "Generating Galois Keys..." << std::endl;
    std::vector<int> galois_steps = find_galois_steps(_rows, true);
    context->set_galois_elts(
        get_elts_from_steps(galois_steps, parms.poly_modulus_degree()));
    galois_keys = std::make_shared<PhantomGaloisKey>(*context);
    secret_key->create_galois_keys(*context, *galois_keys);
    std::cout << "Number:" << galois_steps.size() << std::endl;
  }

  void freeGaloisKeys() {
    galois_keys = nullptr;
  }

  LTPreKey genPreKey(TFHESecretKey &sk, size_t tfhe_n) {
    LTPreKey pre_key;
    LWEsToRLWEKeyGen(*context, pre_key, std::pow(2., modulus_bits), *secret_key,
                     sk, tfhe_n, *ckks_encoder);
    return std::move(pre_key);
  }

  ~PhantomRLWE() {}

#if 0
      void saveSecretKey(std::ostream &stream)
      {
        auto old_except_mask = stream.exceptions();
        try {
          stream.exceptions(std::ios_base::badbit | std::ios_base::failbit);

          stream.write(reinterpret_cast<const char *>(&secret_key->chain_index_), sizeof(uint64_t));
          stream.write(reinterpret_cast<const char *>(&secret_key->gen_flag_), sizeof(bool));
          stream.write(reinterpret_cast<const char *>(&secret_key->sk_max_power_), sizeof(uint64_t));
          stream.write(reinterpret_cast<const char *>(&secret_key->poly_modulus_degree_), sizeof(uint64_t));
          stream.write(reinterpret_cast<const char *>(&secret_key->coeff_modulus_size_), sizeof(uint64_t));

          uint64_t data_rns_size = secret_key->poly_modulus_degree_ * secret_key->coeff_modulus_size_;
          stream.write(reinterpret_cast<const char *>(&data_rns_size), sizeof(uint64_t));

          std::vector<uint64_t> temp_data;
          temp_data.resize(data_rns_size);
          CUDA_CHECK_RETURN(cudaMemcpy(temp_data.data(), secret_key->data_rns_.get(), data_rns_size * sizeof(uint64_t), cudaMemcpyDeviceToHost));
          stream.write(reinterpret_cast<const char *>(temp_data.data()),
              static_cast<std::streamsize>(phantom::util::mul_safe(data_rns_size, sizeof(uint64_t))));

          uint64_t secret_key_array_size = secret_key->sk_max_power_ * secret_key->poly_modulus_degree_ * secret_key->coeff_modulus_size_;
          std::cout << "Secret Key Array Size: " << secret_key_array_size << std::endl;
          stream.write(reinterpret_cast<const char *>(&secret_key_array_size), sizeof(uint64_t));

          temp_data.resize(secret_key_array_size);
          CUDA_CHECK_RETURN(cudaMemcpy(temp_data.data(), secret_key->secret_key_array_.get(), secret_key_array_size * sizeof(uint64_t), cudaMemcpyDeviceToHost));
          stream.write(reinterpret_cast<const char *>(temp_data.data()),
              static_cast<std::streamsize>(phantom::util::mul_safe(secret_key_array_size, sizeof(uint64_t))));
        }
        catch (const std::ios_base::failure &) {
          stream.exceptions(old_except_mask);
          throw std::runtime_error("I/O error");
        }
        catch (...) {
          stream.exceptions(old_except_mask);
          throw;
        }
        stream.exceptions(old_except_mask);
      }

      void loadSecretKey(std::istream &stream)
      {
        auto old_except_mask = stream.exceptions();
        try {
          stream.exceptions(std::ios_base::badbit | std::ios_base::failbit);
          stream.read(reinterpret_cast<char *>(&secret_key->chain_index_), sizeof(uint64_t));
          stream.read(reinterpret_cast<char *>(&secret_key->gen_flag_), sizeof(bool));
          stream.read(reinterpret_cast<char *>(&secret_key->sk_max_power_), sizeof(uint64_t));
          stream.read(reinterpret_cast<char *>(&secret_key->poly_modulus_degree_), sizeof(uint64_t));
          stream.read(reinterpret_cast<char *>(&secret_key->coeff_modulus_size_), sizeof(uint64_t));
          uint64_t data_rns_size = 0;
          stream.read(reinterpret_cast<char *>(&data_rns_size), sizeof(uint64_t));

          std::vector<uint64_t> temp_data;
          temp_data.resize(data_rns_size);
          stream.read(reinterpret_cast<char *>(temp_data.data()),
              static_cast<std::streamsize>(phantom::util::mul_safe(data_rns_size, sizeof(uint64_t))));

          CUDA_CHECK_RETURN(cudaMemcpy(secret_key->data_rns_.get(), temp_data.data(), data_rns_size * sizeof(uint64_t), cudaMemcpyHostToDevice));

          uint64_t secret_key_array_size = 0;
          stream.read(reinterpret_cast<char *>(&secret_key_array_size), sizeof(uint64_t));
          std::cout << "Secret Key Array Size: " << secret_key_array_size << std::endl;
          temp_data.resize(secret_key_array_size);
          stream.read(reinterpret_cast<char *>(temp_data.data()),
            static_cast<std::streamsize>(phantom::util::mul_safe(secret_key_array_size, sizeof(uint64_t))));
          secret_key->secret_key_array_.acquire(
              phantom::util::allocate<uint64_t>(phantom::util::global_pool(), secret_key_array_size));
          CUDA_CHECK_RETURN(cudaMemcpy(secret_key->secret_key_array_.get(), temp_data.data(), secret_key_array_size * sizeof(uint64_t), cudaMemcpyHostToDevice));
        }
        catch (const std::ios_base::failure &) {
          stream.exceptions(old_except_mask);
          throw std::runtime_error("I/O error");
        }
        catch (...) {
          stream.exceptions(old_except_mask);
          throw;
        }
        stream.exceptions(old_except_mask);
      }

      void offload()
      {
        if (!is_buffered)
        {
          std::ostream outputStream(&buffer);
          saveSecretKey(outputStream);
          relin_keys->save(outputStream);
          galois_keys->save(outputStream);
          is_buffered = true;
        }
        context = nullptr;
        secret_key = nullptr;
        relin_keys = nullptr;
        galois_keys = nullptr;
        ckks_encoder = nullptr;
      }

      void reload()
      {
        if (is_buffered)
        {
          context = std::make_shared<PhantomContext>(parms);
          secret_key = std::make_shared<PhantomSecretKey>(parms);
          relin_keys = std::make_shared<PhantomRelinKey>(*context);
          galois_keys = std::make_shared<PhantomGaloisKey>(*context);
          ckks_encoder = std::make_shared<PhantomCKKSEncoder>(*context);

          std::istream inputStream(&buffer);
          loadSecretKey(inputStream);
          relin_keys->load(*context, inputStream);
          galois_keys->load(*context, inputStream);
        }
        else throw std::runtime_error("No buffer available.");
      }
#endif
};
}
