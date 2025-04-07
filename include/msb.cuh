#pragma once

// This code was modified based on HE3DB: https://github.com/zhouzhangwalker/HE3DB

#include "msb_utils.cuh"
#include "gate.cuh"

namespace opera
{
  using namespace cuTFHEpp;
  using namespace cuTFHEpp::util;

  template<bool result_type>
    __host__ void ExtractMSB5(
        const Context &context,
        Pointer<BootstrappingData<Lvl01>> &bs_data,
        TFHEpp::TLWE<Lvl1> *res,
        TFHEpp::TLWE<Lvl1> *tlwe,
        size_t batch_size)
    {
      MSBGateBootstrapping<Lvl10, Lvl01, result_type>(context, bs_data, res, tlwe, batch_size);
    }

  template<bool result_type>
    __host__ void ExtractMSB(
        const Context &context,
        Pointer<BootstrappingData<Lvl01>> &bs_data,
        TFHEpp::TLWE<Lvl1> *res,
        TFHEpp::TLWE<Lvl1> *tlwe,
        TFHEpp::TLWE<Lvl1> *tlwe_temp,
        uint32_t plain_bits,
        size_t batch_size)
    {
      const uint32_t scale_bits = std::numeric_limits<Lvl1::T>::digits - plain_bits;

      // shift_tlwe = tlwe << (plain_bits - 5)
      HomLShift<Lvl1><<<GRID_DIM, BLOCK_DIM>>>(tlwe_temp, tlwe, plain_bits - 5, batch_size);

      // sign_tlwe5
      MSBGateBootstrapping<Lvl10, Lvl01, ARITHMETIC>(context, bs_data, res, tlwe_temp, batch_size);

      // shift_tlwe - sign_tlwe5
      HomSUB<Lvl1><<<GRID_DIM, BLOCK_DIM>>>(tlwe_temp, tlwe_temp, res, batch_size);

      // shift_tlwe
      IdeGateBootstrapping<Lvl10, Lvl01>(context, bs_data, res, tlwe_temp, scale_bits, batch_size);

      // res = tlwe - shift_tlwe
      HomSUB<Lvl1><<<GRID_DIM, BLOCK_DIM>>>(tlwe, tlwe, res, batch_size);
    }

  template<bool result_type>
    __host__ void ImExtractMSB5(
        const Context &context,
        Pointer<BootstrappingData<Lvl02>> &bs_data,
        TFHEpp::TLWE<Lvl2> *res,
        TFHEpp::TLWE<Lvl2> *tlwe,
        size_t batch_size)
    {
      // IdentityKeySwitch<Lvl21>(tlwe1_temp, tlwe, ksk21);

      // ExtractMSB5<result_type>(res, tlwe1_temp, tlwe_low, acc, temp, trlwefft, decpoly, decpolyfft, testvector, bkfft, ksk10);

      MSBGateBootstrapping<Lvl20, Lvl01, result_type>(
          context, bs_data.safe_cast<BootstrappingData<Lvl01>>(),
          reinterpret_cast<TLWELvl1 *>(res), tlwe, batch_size);
    }

  template<bool result_type>
    __host__ void ImExtractMSB9(
        const Context &context,
        Pointer<BootstrappingData<Lvl02>> &bs_data,
        TFHEpp::TLWE<Lvl2> *res,
        TFHEpp::TLWE<Lvl2> *tlwe,
        TFHEpp::TLWE<Lvl2> *tlwe_temp,
        uint32_t plain_bits,
        size_t batch_size)
    {
      auto &bs_data_lvl01 = bs_data.safe_cast<BootstrappingData<Lvl01>>();
      TLWELvl1 *res_lvl1 = reinterpret_cast<TLWELvl1 *>(res);
      TLWELvl1 *tlwe_lvl1 = reinterpret_cast<TLWELvl1 *>(tlwe);
      TLWELvl1 *tlwe_temp_lvl1 = reinterpret_cast<TLWELvl1 *>(tlwe_temp);

      IdentityKeySwitch<Lvl21><<<GRID_DIM, BLOCK_DIM>>>(context, tlwe_temp_lvl1, tlwe, batch_size);

      ExtractMSB<result_type>(context, bs_data_lvl01, res_lvl1, tlwe_temp_lvl1, tlwe_lvl1, plain_bits, batch_size);

      ExtractMSB5<result_type>(context, bs_data_lvl01, res_lvl1, tlwe_temp_lvl1, batch_size);
    }

  template<bool result_type>
    __host__ void ImExtractMSB(
        const Context &context,
        Pointer<BootstrappingData<Lvl02>> &bs_data,
        TFHEpp::TLWE<Lvl2> *res,
        TFHEpp::TLWE<Lvl2> *tlwe,
        TFHEpp::TLWE<Lvl2> *tlwe_temp,
        uint32_t plain_bits,
        size_t batch_size)
    {
      const uint32_t scale_bits = std::numeric_limits<Lvl2::T>::digits - plain_bits;

      // shift_tlwe = tlwe << (plain_bits - 6)
      HomLShift<Lvl2><<<GRID_DIM, BLOCK_DIM>>>(tlwe_temp, tlwe, plain_bits - 6, batch_size);

      // sign_tlwe6
      MSBGateBootstrapping<Lvl20, Lvl02, ARITHMETIC>(context, bs_data, res, tlwe_temp, batch_size);

      // shift_tlwe - sign_tlwe6
      HomSUB<Lvl2><<<GRID_DIM, BLOCK_DIM>>>(tlwe_temp, tlwe_temp, res, batch_size);

      // shift_tlwe
      IdeGateBootstrapping<Lvl20, Lvl02>(context, bs_data, res, tlwe_temp, scale_bits, batch_size);

      // res = tlwe - shift_tlwe
      HomSUB<Lvl2><<<GRID_DIM, BLOCK_DIM>>>(tlwe, tlwe, res, batch_size);
    }

  template<typename LvlXY, bool result_type, typename LvlY = LvlXY::targetP>
    __host__ void HomMSB(
        const Context &context,
        Pointer<BootstrappingData<LvlXY>> &bs_data,
        TFHEpp::TLWE<LvlY> *res,
        TFHEpp::TLWE<LvlY> *tlwe,
        TFHEpp::TLWE<LvlY> *tlwe_temp,
        uint32_t plain_bits,
        size_t batch_size)
    {
      if constexpr (std::is_same<LvlXY, Lvl01>::value) {
        assert(plain_bits <= 10);

        while (plain_bits > 5) {
          ExtractMSB<result_type>(context, bs_data, res, tlwe, tlwe_temp, plain_bits, batch_size);
          plain_bits -= 4;
        }

        ExtractMSB5<result_type>(context, bs_data, res, tlwe, batch_size);
      }
      else if constexpr (std::is_same<LvlXY, Lvl02>::value) {
        assert(plain_bits <= 33);

        while (plain_bits > 9) {
          ImExtractMSB<result_type>(context, bs_data, res, tlwe, tlwe_temp, plain_bits, batch_size);
          plain_bits -= 5;
        }

        if (plain_bits > 5)
          ImExtractMSB9<result_type>(context, bs_data, res, tlwe, tlwe_temp, plain_bits, batch_size);
        else
          ImExtractMSB5<result_type>(context, bs_data, res, tlwe, batch_size);
      }
      else static_assert(TFHEpp::false_v<LvlXY>, "Unsupported MSB");
    }
} // namespace opera
