#pragma once

#include <tfhe++.hpp>
#include <fstream>
#include <iostream>
#include "types.h"
#include "utils.cuh"

#define SECRET_KEY_NAME "secret.key"
#define EVAL_KEY_NAME_BKFFTLVL01 "bkfftlvl01.key"
#define EVAL_KEY_NAME_BKFFTLVL02 "bkfftlvl02.key"
#define EVAL_KEY_NAME_IKSKLVL10 "iksklvl10.key"
#define EVAL_KEY_NAME_IKSKLVL20 "iksklvl20.key"
#define EVAL_KEY_NAME_IKSKLVL21 "iksklvl21.key"
#define LOAD_KEY 1
#define STORE_KEY 0
#define IS_LOAD_KEY(a) a
#define IS_STORE_KEY(a) !a

namespace cuTFHEpp
{
  template<class P>
  inline std::string get_evalkey_path(const char *path)
  {
    if constexpr (std::is_same_v<P, BootstrappingKeyFFTLvl01>)
      return std::string(path) + "/" + EVAL_KEY_NAME_BKFFTLVL01;
    else if constexpr (std::is_same_v<P, BootstrappingKeyFFTLvl02>)
      return std::string(path) + "/" + EVAL_KEY_NAME_BKFFTLVL02;
    else if constexpr (std::is_same_v<P, KeySwitchingKeyLvl10>)
      return std::string(path) + "/" + EVAL_KEY_NAME_IKSKLVL10;
    else if constexpr (std::is_same_v<P, KeySwitchingKeyLvl20>)
      return std::string(path) + "/" + EVAL_KEY_NAME_IKSKLVL20;
    else if constexpr (std::is_same_v<P, KeySwitchingKeyLvl21>)
      return std::string(path) + "/" + EVAL_KEY_NAME_IKSKLVL21;
    else
      static_assert(TFHEpp::false_v<P>, "Unsupported EvalKey Type");
  }

  template<class P, class Archive>
  inline void evalkey_serilize(TFHEEvalKey &ek, Archive &ar)
  {
    if constexpr (std::is_same_v<P, BootstrappingKeyFFTLvl01>)
      ek.serialize_bkfftlvl01(ar);
    else if constexpr (std::is_same_v<P, BootstrappingKeyFFTLvl02>)
      ek.serialize_bkfftlvl02(ar);
    else if constexpr (std::is_same_v<P, KeySwitchingKeyLvl10>)
      ek.serialize_iksklvl10(ar);
    else if constexpr (std::is_same_v<P, KeySwitchingKeyLvl20>)
      ek.serialize_iksklvl20(ar);
    else if constexpr (std::is_same_v<P, KeySwitchingKeyLvl21>)
      ek.serialize_iksklvl21(ar);
    else
      static_assert(TFHEpp::false_v<P>, "Unsupported EvalKey Type");
  }

  template<class P>
  inline decltype(auto) get_evalkey(TFHEEvalKey &ek)
  {
    if constexpr (std::is_same_v<P, BootstrappingKeyFFTLvl01>)
      return ek.bkfftlvl01.get();
    else if constexpr (std::is_same_v<P, BootstrappingKeyFFTLvl02>)
      return ek.bkfftlvl02.get();
    else if constexpr (std::is_same_v<P, KeySwitchingKeyLvl10>)
      return ek.iksklvl10.get();
    else if constexpr (std::is_same_v<P, KeySwitchingKeyLvl20>)
      return ek.iksklvl20.get();
    else if constexpr (std::is_same_v<P, KeySwitchingKeyLvl21>)
      return ek.iksklvl21.get();
    else
      static_assert(TFHEpp::false_v<P>, "Unsupported EvalKey Type");
  }

  template<bool type>
  void serializeSecretKey(TFHESecretKey &sk)
  {
    using Archive = std::conditional_t<IS_LOAD_KEY(type), cereal::PortableBinaryInputArchive, cereal::PortableBinaryOutputArchive>;
    using FileStream = std::conditional_t<IS_LOAD_KEY(type), std::ifstream, std::ofstream>;

    std::string file_path = std::string("./") + SECRET_KEY_NAME;
    FileStream fs{file_path, std::ios::binary};
    Archive ar(fs);
    sk.serialize(ar);
  }

  template<class P, bool type>
  void serializeEvalKey(TFHEEvalKey &ek)
  {
    if constexpr (IS_STORE_KEY(type)) assert(get_evalkey<P>(ek));
    using Archive = std::conditional_t<IS_LOAD_KEY(type), cereal::PortableBinaryInputArchive, cereal::PortableBinaryOutputArchive>;
    using FileStream = std::conditional_t<IS_LOAD_KEY(type), std::ifstream, std::ofstream>;

    std::string file_path = get_evalkey_path<P>(".");
    FileStream fs{file_path, std::ios::binary};
    Archive ar(fs);
    evalkey_serilize<P>(ek, ar);
  }

  template<typename P>
  void load_evalkeys(TFHESecretKey &sk, TFHEEvalKey &ek) {}

  template<typename P, typename Head, typename ... Tail>
  void load_evalkeys(TFHESecretKey &sk, TFHEEvalKey &ek)
  {
    try
    {
        serializeEvalKey<Head, LOAD_KEY>(ek);
    }
    catch(const std::exception& e)
    {
        std::cerr << "Failed to load EvalKey, generating new key" << '\n';
        if constexpr (std::is_same_v<Head, BootstrappingKeyFFTLvl01>)
          ek.emplacebkfft<Lvl01>(sk);
        else if constexpr (std::is_same_v<Head, BootstrappingKeyFFTLvl02>)
          ek.emplacebkfft<Lvl02>(sk);
        else if constexpr (std::is_same_v<Head, KeySwitchingKeyLvl10>)
          ek.emplaceiksk<Lvl10>(sk);
        else if constexpr (std::is_same_v<Head, KeySwitchingKeyLvl20>)
          ek.emplaceiksk<Lvl20>(sk);
        else if constexpr (std::is_same_v<Head, KeySwitchingKeyLvl21>)
          ek.emplaceiksk<Lvl21>(sk);
        else
          static_assert(TFHEpp::false_v<Head>, "Unsupported EvalKey Type");
        serializeEvalKey<Head, STORE_KEY>(ek);
    }
    load_evalkeys<P, Tail...>(sk, ek);
  }

  template<typename ... Keys>
  void load_keys(TFHESecretKey &sk, TFHEEvalKey &ek)
  {
    try
    {
      std::cout << "try loading keys" << std::endl;
      serializeSecretKey<LOAD_KEY>(sk);
    }
    catch(const std::exception& e)
    {
      std::cout << "Failed to load SecretKey, generating new key" << '\n';
      serializeSecretKey<STORE_KEY>(sk);
    }

    load_evalkeys<void, Keys...>(sk, ek);
  }
} // namespace cuTFHEpp
