#pragma once

// This code was modified based on HE3DB: https://github.com/zhouzhangwalker/HE3DB

#include <cutfhe++.h>
#include "utils.h"

namespace opera
{
  using namespace cuTFHEpp;
  using namespace cuTFHEpp::util;

  template<class P>
  inline constexpr uint32_t get_offset_bits()
  {
    if constexpr (std::is_same_v<P, Lvl1>)
      return 6;
    else if constexpr (std::is_same_v<P, Lvl2>)
      return 7;
    else
      static_assert(TFHEpp::false_v<P>, "Undefined offset_bits");
  }

  template<typename LvlXY, typename LvlYZ, bool result_type,
    typename LvlX = LvlXY::domainP, typename LvlY = LvlXY::targetP, typename LvlZ = LvlYZ::targetP>
    void MSBGateBootstrapping(
        const Context &context,
        Pointer<BootstrappingData<LvlYZ>> &bs_data,
        TFHEpp::TLWE<LvlZ> *res,
        TFHEpp::TLWE<LvlX> *tlwe,
        const size_t batch_size)
    {
      static_assert(std::is_same_v<LvlY, typename LvlYZ::domainP>, "Invalid KeySwitching target or bootstrapping domain");

      constexpr uint32_t offset_bits = get_offset_bits<LvlZ>();
      constexpr typename LvlX::T offset = 1ULL << (std::numeric_limits<typename LvlX::T>::digits - offset_bits);
      constexpr typename LvlZ::T mu = IS_ARITHMETIC(result_type) ? LvlZ::μ << 1 : LvlZ::μ;

      HomADD_plain<LvlX><<<1,BLOCK_DIM>>>(tlwe, tlwe, offset, batch_size);
      IdentityKeySwitch<LvlXY><<<GRID_DIM, BLOCK_DIM>>>(context, bs_data->tlwe_from, tlwe, batch_size);
      HomADD_plain<LvlX><<<1,BLOCK_DIM>>>(tlwe, tlwe, -offset, batch_size);

      mu_polygen<LvlZ><<<1, BLOCK_DIM>>>(*bs_data->testvector, -mu);
      constexpr size_t shared_mem_size = SHM_SIZE<LvlZ>;
      GateBootstrappingTLWE2TLWEFFT<LvlYZ><<<GRID_DIM, BLOCK_DIM, shared_mem_size>>>(context, bs_data.get(), res, batch_size);

      if constexpr (IS_ARITHMETIC(result_type))
        HomADD_plain<LvlZ><<<1,BLOCK_DIM>>>(res, res, mu, batch_size);
    }

  template<typename LvlXY, typename LvlYZ,
    typename LvlX = LvlXY::domainP, typename LvlY = LvlXY::targetP, typename LvlZ = LvlYZ::targetP>
    void IdeGateBootstrapping(
        const Context &context,
        Pointer<BootstrappingData<LvlYZ>> &bs_data,
        TFHEpp::TLWE<LvlZ> *res,
        TFHEpp::TLWE<LvlX> *tlwe,
        uint32_t scale_bits,
        size_t batch_size)
    {
      static_assert(std::is_same_v<LvlY, typename LvlYZ::domainP>, "Invalid KeySwitching target or bootstrapping domain");

      constexpr uint32_t offset_bits = get_offset_bits<LvlZ>();
      constexpr uint32_t plain_bits = offset_bits - 2;
      constexpr typename LvlX::T offset = 1ULL << (std::numeric_limits<typename LvlX::T>::digits - offset_bits);

      HomADD_plain<LvlX><<<1,BLOCK_DIM>>>(tlwe, tlwe, offset, batch_size);
      IdentityKeySwitch<LvlXY><<<GRID_DIM, BLOCK_DIM>>>(context, bs_data->tlwe_from, tlwe, batch_size);
      HomADD_plain<LvlX><<<1,BLOCK_DIM>>>(tlwe, tlwe, -offset, batch_size);

      gpolygen<LvlZ, plain_bits><<<1, BLOCK_DIM>>>(*bs_data->testvector, scale_bits);
      constexpr size_t shared_mem_size = SHM_SIZE<LvlZ>;
      GateBootstrappingTLWE2TLWEFFT<LvlYZ><<<GRID_DIM, BLOCK_DIM, shared_mem_size>>>(context, bs_data.get(), res, batch_size);
    }

  template<typename LvlXY, typename LvlYZ,
    typename LvlX = LvlXY::domainP, typename LvlY = LvlXY::targetP, typename LvlZ = LvlYZ::targetP>
    void LOGtoARI(
        const Context &context,
        Pointer<BootstrappingData<LvlYZ>> &bs_data,
        TFHEpp::TLWE<LvlZ> *res,
        TFHEpp::TLWE<LvlX> *tlwe,
        const size_t batch_size)
    {
      static_assert(std::is_same_v<LvlY, typename LvlYZ::domainP>, "Invalid KeySwitching target or bootstrapping domain");

      constexpr typename LvlZ::T mu = LvlZ::μ << 1;

      IdentityKeySwitch<LvlXY><<<GRID_DIM, BLOCK_DIM>>>(context, bs_data->tlwe_from, tlwe, batch_size);

      mu_polygen<LvlZ><<<1, BLOCK_DIM>>>(*bs_data->testvector, mu);
      constexpr size_t shared_mem_size = SHM_SIZE<LvlZ>;
      GateBootstrappingTLWE2TLWEFFT<LvlYZ><<<GRID_DIM, BLOCK_DIM, shared_mem_size>>>(context, bs_data.get(), res, batch_size);

      HomADD_plain<LvlZ><<<1,BLOCK_DIM>>>(res, res, mu, batch_size);
    }

  template<typename LvlXY, typename LvlYZ,
    typename LvlX = LvlXY::domainP, typename LvlY = LvlXY::targetP, typename LvlZ = LvlYZ::targetP>
    void ari_rescale(
        const Context &context,
        Pointer<BootstrappingData<LvlYZ>> &bs_data,
        TFHEpp::TLWE<LvlZ> *res,
        TFHEpp::TLWE<LvlX> *tlwe,
        const uint32_t scale_bits,
        const size_t batch_size)
    {
      static_assert(std::is_same_v<LvlY, typename LvlYZ::domainP>, "Invalid KeySwitching target or bootstrapping domain");

      constexpr typename LvlX::T offset = 1ULL << (std::numeric_limits<typename LvlX::T>::digits - 6);
      const typename LvlZ::T mu = 1ULL << (scale_bits - 1);

      HomADD_plain<LvlX><<<1,BLOCK_DIM>>>(tlwe, tlwe, offset, batch_size);
      IdentityKeySwitch<LvlXY><<<GRID_DIM, BLOCK_DIM>>>(context, bs_data->tlwe_from, tlwe, batch_size);
      HomADD_plain<LvlX><<<1,BLOCK_DIM>>>(tlwe, tlwe, -offset, batch_size);

      mu_polygen<LvlZ><<<1, BLOCK_DIM>>>(*bs_data->testvector, -mu);
      constexpr size_t shared_mem_size = SHM_SIZE<LvlZ>;
      GateBootstrappingTLWE2TLWEFFT<LvlYZ><<<GRID_DIM, BLOCK_DIM, shared_mem_size>>>(context, bs_data.get(), res, batch_size);

      HomADD_plain<LvlZ><<<1,BLOCK_DIM>>>(res, res, mu, batch_size);
    }

  template<typename LvlXY, typename LvlYZ,
    typename LvlX = LvlXY::domainP, typename LvlY = LvlXY::targetP, typename LvlZ = LvlYZ::targetP>
    void ari_rescale(
        const Context &context,
        Pointer<BootstrappingData<LvlYZ>> &bs_data,
        Pointer<cuTLWE<LvlX>> *tlwe_data,
        TFHEpp::TLWE<LvlZ> *res,
        const TFHEpp::TLWE<LvlX> *tlwe,
        const uint32_t scale_bits,
        const size_t batch_size)
    {
      TFHEpp::TLWE<LvlZ> *pt_res = tlwe_data[0]->template get<LvlZ>();
      TFHEpp::TLWE<LvlX> *pt_tlwe = tlwe_data[1]->template get<LvlX>();

      CUDA_CHECK_RETURN(cudaMemcpy(pt_tlwe, tlwe, sizeof(TFHEpp::TLWE<LvlX>) * batch_size, cudaMemcpyHostToDevice));

      ari_rescale<LvlXY, LvlYZ>(context, bs_data, pt_res, pt_tlwe, scale_bits, batch_size);

      CUDA_CHECK_RETURN(cudaMemcpy(res, pt_res, sizeof(TFHEpp::TLWE<LvlZ>) * batch_size, cudaMemcpyDeviceToHost));
    }
}
