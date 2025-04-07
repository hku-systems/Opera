#pragma once

#include <cutfhe++.h>
#include "utils.h"

namespace opera
{
  template<typename LvlX, bool result_type,
    typename Lvl0X = LvlXY<Lvl0, LvlX>::T, typename LvlX0 = LvlXY<LvlX, Lvl0>::T>
    void HomAND(
        const Context &context,
        util::Pointer<BootstrappingData<Lvl0X>> &bs_data,
        TFHEpp::TLWE<LvlX> *res,
        const TFHEpp::TLWE<LvlX> *tlwe1,
        const TFHEpp::TLWE<LvlX> *tlwe2,
        const size_t batch_size)
    {
      constexpr typename LvlX::T offset = IS_ARITHMETIC(result_type) ? LvlX::μ << 1 : LvlX::μ;

      HomADD<LvlX><<<GRID_DIM, BLOCK_DIM>>>(res, tlwe1, tlwe2, batch_size);
      HomADD_plain<LvlX><<<1, BLOCK_DIM>>>(res, res, -(LvlX::μ >> 1), batch_size);

      IdentityKeySwitch<LvlX0><<<GRID_DIM, BLOCK_DIM>>>(context, bs_data->tlwe_from, res, batch_size);

      mu_polygen<LvlX><<<1, BLOCK_DIM>>>(*bs_data->testvector, offset);

      constexpr size_t shared_mem_size = SHM_SIZE<LvlX>;
      GateBootstrappingTLWE2TLWEFFT<Lvl0X><<<GRID_DIM, BLOCK_DIM, shared_mem_size>>>(context, bs_data.get(), res, batch_size);

      if constexpr (IS_ARITHMETIC(result_type))
        HomADD_plain<LvlX><<<1, BLOCK_DIM>>>(res, res, offset, batch_size);
    }

#define OPERA_HOMAND(X,Y)                                  \
  template void HomAND<Lvl##X,Y>(                           \
        const Context &context,                             \
        util::Pointer<BootstrappingData<Lvl0##X>> &bs_data, \
        TFHEpp::TLWE<Lvl##X> *res,                          \
        const TFHEpp::TLWE<Lvl##X> *tlwe1,                  \
        const TFHEpp::TLWE<Lvl##X> *tlwe2,                  \
        const size_t batch_size)

  EXPLICIT_LVL_LOG_ARI_EXTERN(OPERA_HOMAND);

  template<bool result_type>
    void HomAND(
        const Context &context,
        util::Pointer<BootstrappingData<Lvl01>> &bs_data,
        util::Pointer<cuTLWE<Lvl1>> *tlwe_data,
        TFHEpp::TLWE<Lvl1> *res,
        const TFHEpp::TLWE<Lvl1> *tlwe1,
        const TFHEpp::TLWE<Lvl1> *tlwe2,
        const size_t batch_size,
        double &accumulated_time)
    {
      TLWELvl1 *pt_res = tlwe_data[0]->template get<Lvl1>();
      TLWELvl1 *pt_tlwe1 = tlwe_data[1]->template get<Lvl1>();
      TLWELvl1 *pt_tlwe2 = tlwe_data[2]->template get<Lvl1>();

      CUDA_CHECK_RETURN(cudaMemcpy(pt_tlwe1, tlwe1, sizeof(TFHEpp::TLWE<Lvl1>) * batch_size, cudaMemcpyHostToDevice));
      CUDA_CHECK_RETURN(cudaMemcpy(pt_tlwe2, tlwe2, sizeof(TFHEpp::TLWE<Lvl1>) * batch_size, cudaMemcpyHostToDevice));

      cudaEvent_t start, stop;
      RECORD_TIME_START(start, stop);
      HomAND<Lvl1, result_type>(context, bs_data, pt_res, pt_tlwe1, pt_tlwe2, batch_size);
      accumulated_time += RECORD_TIME_END(start, stop);

      CUDA_CHECK_RETURN(cudaMemcpy(res, pt_res, sizeof(TFHEpp::TLWE<Lvl1>) * batch_size, cudaMemcpyDeviceToHost));
    }


  template<typename LvlX, bool result_type,
    typename Lvl0X = LvlXY<Lvl0, LvlX>::T, typename LvlX0 = LvlXY<LvlX, Lvl0>::T>
    void HomOR(
        const Context &context,
        util::Pointer<BootstrappingData<Lvl0X>> &bs_data,
        TFHEpp::TLWE<LvlX> *res,
        const TFHEpp::TLWE<LvlX> *tlwe1,
        const TFHEpp::TLWE<LvlX> *tlwe2,
        const size_t batch_size)
    {
      constexpr typename Lvl1::T offset = IS_ARITHMETIC(result_type) ? Lvl1::μ << 1 : Lvl1::μ;

      HomADD<LvlX><<<GRID_DIM, BLOCK_DIM>>>(res, tlwe1, tlwe2, batch_size);
      HomADD_plain<LvlX><<<1, BLOCK_DIM>>>(res, res, LvlX::μ >> 1, batch_size);

      IdentityKeySwitch<LvlX0><<<GRID_DIM, BLOCK_DIM>>>(context, bs_data->tlwe_from, res, batch_size);

      mu_polygen<LvlX><<<1, BLOCK_DIM>>>(*bs_data->testvector, offset);

      constexpr size_t shared_mem_size = SHM_SIZE<LvlX>;
      GateBootstrappingTLWE2TLWEFFT<Lvl0X><<<GRID_DIM, BLOCK_DIM, shared_mem_size>>>(context, bs_data.get(), res, batch_size);

      if constexpr (IS_ARITHMETIC(result_type))
        HomADD_plain<LvlX><<<1, BLOCK_DIM>>>(res, res, offset, batch_size);
    }

#define OPERA_HOMOR(X,Y)                                   \
  template void HomOR<Lvl##X,Y>(                            \
        const Context &context,                             \
        util::Pointer<BootstrappingData<Lvl0##X>> &bs_data, \
        TFHEpp::TLWE<Lvl##X> *res,                          \
        const TFHEpp::TLWE<Lvl##X> *tlwe1,                  \
        const TFHEpp::TLWE<Lvl##X> *tlwe2,                  \
        const size_t batch_size)

  EXPLICIT_LVL_LOG_ARI_EXTERN(OPERA_HOMOR);

  template<bool result_type>
    void HomOR(
        const Context &context,
        util::Pointer<BootstrappingData<Lvl01>> &bs_data,
        util::Pointer<cuTLWE<Lvl1>> *tlwe_data,
        TFHEpp::TLWE<Lvl1> *res,
        const TFHEpp::TLWE<Lvl1> *tlwe1,
        const TFHEpp::TLWE<Lvl1> *tlwe2,
        const size_t batch_size,
        double &accumulated_time)
    {
      TLWELvl1 *pt_res = tlwe_data[0]->template get<Lvl1>();
      TLWELvl1 *pt_tlwe1 = tlwe_data[1]->template get<Lvl1>();
      TLWELvl1 *pt_tlwe2 = tlwe_data[2]->template get<Lvl1>();

      CUDA_CHECK_RETURN(cudaMemcpy(pt_tlwe1, tlwe1, sizeof(TFHEpp::TLWE<Lvl1>) * batch_size, cudaMemcpyHostToDevice));
      CUDA_CHECK_RETURN(cudaMemcpy(pt_tlwe2, tlwe2, sizeof(TFHEpp::TLWE<Lvl1>) * batch_size, cudaMemcpyHostToDevice));

      cudaEvent_t start, stop;
      RECORD_TIME_START(start, stop);
      HomOR<Lvl1, result_type>(context, bs_data, pt_res, pt_tlwe1, pt_tlwe2, batch_size);
      accumulated_time += RECORD_TIME_END(start, stop);

      CUDA_CHECK_RETURN(cudaMemcpy(res, pt_res, sizeof(TFHEpp::TLWE<Lvl1>) * batch_size, cudaMemcpyDeviceToHost));
    }
} // namespace opera
