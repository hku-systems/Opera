#pragma once

#include <cutfhe++.h>
#include "operator.cuh"

#define TLWE_RES_IDX     0
#define TLWE_CIPHER1_IDX 1
#define TLWE_CIPHER2_IDX 2
#define TLWE_TEMP_IDX    3
#define NUM_HOMCOMP_TLWE 4

namespace opera
{
  using namespace cuTFHEpp;
  using namespace cuTFHEpp::util;

  template<typename LvlXY, bool result_type, typename LvlY = LvlXY::targetP>
    void greater_than(
        const Context &context,
        Pointer<BootstrappingData<LvlXY>> &bs_data,
        TFHEpp::TLWE<LvlY> *res,
        TFHEpp::TLWE<LvlY> *cipher1,
        TFHEpp::TLWE<LvlY> *cipher2,
        uint32_t plain_bits,
        size_t batch_size,
        uint32_t shift_bits = 0)
    {
      // cipher1 = (cipher2 - cipher1) << shift_bits
      HomSUBLShift<LvlY><<<GRID_DIM, BLOCK_DIM>>>(cipher1, cipher2, cipher1, shift_bits, batch_size);

      HomMSB<LvlXY, result_type>(context, bs_data, res, cipher1, cipher2, plain_bits, batch_size);
    }

  template<typename LvlXY, bool result_type, typename LvlY = LvlXY::targetP>
    void greater_than_equal(
        const Context &context,
        Pointer<BootstrappingData<LvlXY>> &bs_data,
        TFHEpp::TLWE<LvlY> *res,
        TFHEpp::TLWE<LvlY> *cipher1,
        TFHEpp::TLWE<LvlY> *cipher2,
        uint32_t plain_bits,
        size_t batch_size,
        uint32_t shift_bits = 0)
    {
      // cipher1 = (cipher2 - cipher1) << shift_bits
      HomSUBLShift<LvlY><<<GRID_DIM, BLOCK_DIM>>>(cipher1, cipher1, cipher2, shift_bits, batch_size);

      HomMSB<LvlXY, LOGIC>(context, bs_data, res, cipher1, cipher2, plain_bits, batch_size);

      TLWELvl1 *res_lvl1 = reinterpret_cast<TLWELvl1 *>(res);

      // res = !res
      HomNOT<Lvl1><<<GRID_DIM, BLOCK_DIM>>>(res_lvl1, res_lvl1, batch_size);

      if constexpr (IS_ARITHMETIC(result_type)) {
        auto &bs_data_lvl01 = bs_data.template safe_cast<BootstrappingData<Lvl01>>();
        LOGtoARI<Lvl10, Lvl01>(context, bs_data_lvl01, res_lvl1, res_lvl1, batch_size);
      }
    }

  template<typename LvlXY, bool result_type, typename LvlY = LvlXY::targetP>
    void less_than(
        const Context &context,
        Pointer<BootstrappingData<LvlXY>> &bs_data,
        TFHEpp::TLWE<LvlY> *res,
        TFHEpp::TLWE<LvlY> *cipher1,
        TFHEpp::TLWE<LvlY> *cipher2,
        uint32_t plain_bits,
        size_t batch_size,
        uint32_t shift_bits = 0)
    {
      // cipher1 = (cipher2 - cipher1) << shift_bits
      HomSUBLShift<LvlY><<<GRID_DIM, BLOCK_DIM>>>(cipher1, cipher1, cipher2, shift_bits, batch_size);

      HomMSB<LvlXY, result_type>(context, bs_data, res, cipher1, cipher2, plain_bits, batch_size);
    }

  template<typename LvlXY, bool result_type, typename LvlY = LvlXY::targetP>
    void less_than_equal(
        const Context &context,
        Pointer<BootstrappingData<LvlXY>> &bs_data,
        TFHEpp::TLWE<LvlY> *res,
        TFHEpp::TLWE<LvlY> *cipher1,
        TFHEpp::TLWE<LvlY> *cipher2,
        uint32_t plain_bits,
        size_t batch_size,
        uint32_t shift_bits = 0)
    {
      // cipher1 = (cipher2 - cipher1) << shift_bits
      HomSUBLShift<LvlY><<<GRID_DIM, BLOCK_DIM>>>(cipher1, cipher2, cipher1, shift_bits, batch_size);

      HomMSB<LvlXY, LOGIC>(context, bs_data, res, cipher1, cipher2, plain_bits, batch_size);

      TLWELvl1 *res_lvl1 = reinterpret_cast<TLWELvl1 *>(res);

      // res = !res
      HomNOT<Lvl1><<<GRID_DIM, BLOCK_DIM>>>(res_lvl1, res_lvl1, batch_size);

      if constexpr (IS_ARITHMETIC(result_type)) {
        auto &bs_data_lvl01 = bs_data.template safe_cast<BootstrappingData<Lvl01>>();
        LOGtoARI<Lvl10, Lvl01>(context, bs_data_lvl01, res_lvl1, res_lvl1, batch_size);
      }
    }

  template<typename LvlXY, bool result_type, typename LvlY = LvlXY::targetP>
    void equal(
        const Context &context,
        Pointer<BootstrappingData<LvlXY>> &bs_data,
        TFHEpp::TLWE<LvlY> *res,
        TFHEpp::TLWE<LvlY> *cipher1,
        TFHEpp::TLWE<LvlY> *cipher2,
        TFHEpp::TLWE<LvlY> *tlwe_temp,
        uint32_t plain_bits,
        size_t batch_size,
        uint32_t shift_bits = 0)
    {
      // cipher1 = (cipher2 - cipher1) << shift_bits
      HomSUBLShift<LvlY><<<GRID_DIM, BLOCK_DIM>>>(cipher1, cipher1, cipher2, shift_bits, batch_size);

      // cipher2 = cipher2 - cipher1
      HomNOT<LvlY><<<GRID_DIM, BLOCK_DIM>>>(cipher2, cipher1, batch_size);

      HomMSB<LvlXY, LOGIC>(context, bs_data, res, cipher1, tlwe_temp, plain_bits, batch_size);

      TLWELvl1 *res_lvl1 = reinterpret_cast<TLWELvl1 *>(res);
      TLWELvl1 *cipher1_lvl1 = reinterpret_cast<TLWELvl1 *>(cipher1);
      TLWELvl1 *cipher2_lvl1 = reinterpret_cast<TLWELvl1 *>(cipher2);
      HomNOT<Lvl1><<<GRID_DIM, BLOCK_DIM>>>(cipher1_lvl1, res_lvl1, batch_size);

      HomMSB<LvlXY, LOGIC>(context, bs_data, res, cipher2, tlwe_temp, plain_bits, batch_size);

      HomNOT<Lvl1><<<GRID_DIM, BLOCK_DIM>>>(cipher2_lvl1, res_lvl1, batch_size);

      HomAND<Lvl1, result_type>(context, bs_data.template safe_cast<BootstrappingData<Lvl01>>(),
          res_lvl1, cipher1_lvl1, cipher2_lvl1, batch_size);
    }

  template<typename LvlXY, CompOp op, bool result_type, typename LvlY = LvlXY::targetP>
    void HomComp(
        const Context &context,
        Pointer<BootstrappingData<LvlXY>> &bs_data,
        TFHEpp::TLWE<LvlY> *res,
        TFHEpp::TLWE<LvlY> *cipher1,
        TFHEpp::TLWE<LvlY> *cipher2,
        TFHEpp::TLWE<LvlY> *tlwe_temp,
        uint32_t plain_bits,
        size_t batch_size,
        uint32_t shift_bits = 0)
    {
      switch (op)
      {
        case GT:
          greater_than<LvlXY, result_type>(
              context, bs_data, res, cipher1, cipher2, plain_bits+1, batch_size, shift_bits);
          break;
        case GE:
          greater_than_equal<LvlXY, result_type>(
              context, bs_data, res, cipher1, cipher2, plain_bits+1, batch_size, shift_bits);
          break;
        case LT:
          less_than<LvlXY, result_type>(
              context, bs_data, res, cipher1, cipher2, plain_bits+1, batch_size, shift_bits);
          break;
        case LE:
          less_than_equal<LvlXY, result_type>(
              context, bs_data, res, cipher1, cipher2, plain_bits+1, batch_size, shift_bits);
          break;
        case EQ:
          equal<LvlXY, result_type>(
              context, bs_data, res, cipher1, cipher2, tlwe_temp, plain_bits+1, batch_size, shift_bits);
          break;
        default:
          throw std::runtime_error("Invalid comparison operator");
      }
      CUDA_CHECK_ERROR();
    }

  template<typename LvlXY, CompOp op, bool result_type, typename LvlY = LvlXY::targetP>
    void HomComp(
        const Context &context,
        Pointer<BootstrappingData<LvlXY>> &bs_data,
        Pointer<cuTLWE<LvlY>> *tlwe_data,
        TFHEpp::TLWE<Lvl1> *res,
        TFHEpp::TLWE<LvlY> *cipher1,
        TFHEpp::TLWE<LvlY> *cipher2,
        uint32_t plain_bits,
        size_t batch_size,
        double &accumulated_time)
    {
      TFHEpp::TLWE<LvlY> *pt_cipher1 = tlwe_data[TLWE_CIPHER1_IDX]->template get<LvlY>();
      TFHEpp::TLWE<LvlY> *pt_cipher2 = tlwe_data[TLWE_CIPHER2_IDX]->template get<LvlY>();
      TFHEpp::TLWE<LvlY> *pt_res = tlwe_data[TLWE_RES_IDX]->template get<LvlY>();
      TFHEpp::TLWE<Lvl1> *pt_res_lvl1 = tlwe_data[TLWE_RES_IDX]->template get<Lvl1>();
      TFHEpp::TLWE<LvlY> *pt_tlwe_temp = tlwe_data[TLWE_TEMP_IDX]->template get<LvlY>();

      CUDA_CHECK_RETURN(cudaMemcpy(pt_cipher1, cipher1, sizeof(TFHEpp::TLWE<LvlY>) * batch_size, cudaMemcpyHostToDevice));
      CUDA_CHECK_RETURN(cudaMemcpy(pt_cipher2, cipher2, sizeof(TFHEpp::TLWE<LvlY>) * batch_size, cudaMemcpyHostToDevice));

      cudaEvent_t start, stop;
      RECORD_TIME_START(start, stop);
      HomComp<LvlXY, op, result_type>(context, bs_data, pt_res, pt_cipher1, pt_cipher2, pt_tlwe_temp, plain_bits, batch_size);
      accumulated_time += RECORD_TIME_END(start, stop);

      CUDA_CHECK_RETURN(cudaMemcpy(res, pt_res_lvl1, sizeof(TFHEpp::TLWE<Lvl1>)*batch_size, cudaMemcpyDeviceToHost));
    }

  template<typename LvlXY, CompOp op, bool result_type, typename LvlY = LvlXY::targetP>
    void HomFastComp(
        Context &context,
        Pointer<BootstrappingData<LvlXY>> &bs_data,
        TFHEpp::TLWE<LvlY> *res,
        TFHEpp::TLWE<LvlY> *cipher1,
        TFHEpp::TLWE<LvlY> *cipher2,
        TFHEpp::TLWE<LvlY> *tlwe_temp,
        uint32_t plain_bits,
        uint32_t pmsb,
        size_t batch_size)
    {
        if (!pmsb) return;
        pmsb = std::min(plain_bits, pmsb);
        uint32_t shift_bits = plain_bits - pmsb;
        HomComp<LvlXY, op, result_type>(context, bs_data, res, cipher1, cipher2, tlwe_temp, pmsb, batch_size, shift_bits);
    }

  template<typename LvlXY, CompOp op, bool result_type, typename LvlY = LvlXY::targetP>
    void HomFastComp(
        Context &context,
        Pointer<BootstrappingData<LvlXY>> &bs_data,
        Pointer<cuTLWE<LvlY>> *tlwe_data,
        TFHEpp::TLWE<Lvl1> *res,
        TFHEpp::TLWE<LvlY> *cipher1,
        TFHEpp::TLWE<LvlY> *cipher2,
        uint32_t plain_bits,
        uint32_t pmsb,
        size_t batch_size,
        double &accumulated_time)
    {
      TFHEpp::TLWE<LvlY> *pt_cipher1 = tlwe_data[TLWE_CIPHER1_IDX]->template get<LvlY>();
      TFHEpp::TLWE<LvlY> *pt_cipher2 = tlwe_data[TLWE_CIPHER2_IDX]->template get<LvlY>();
      TFHEpp::TLWE<LvlY> *pt_res = tlwe_data[TLWE_RES_IDX]->template get<LvlY>();
      TFHEpp::TLWE<Lvl1> *pt_res_lvl1 = tlwe_data[TLWE_RES_IDX]->template get<Lvl1>();
      TFHEpp::TLWE<LvlY> *pt_tlwe_temp = tlwe_data[TLWE_TEMP_IDX]->template get<LvlY>();

      CUDA_CHECK_RETURN(cudaMemcpy(pt_cipher1, cipher1, sizeof(TFHEpp::TLWE<LvlY>) * batch_size, cudaMemcpyHostToDevice));
      CUDA_CHECK_RETURN(cudaMemcpy(pt_cipher2, cipher2, sizeof(TFHEpp::TLWE<LvlY>) * batch_size, cudaMemcpyHostToDevice));

      cudaEvent_t start, stop;
      RECORD_TIME_START(start, stop);

      HomFastComp<LvlXY, op, result_type>(context, bs_data, pt_res, pt_cipher1, pt_cipher2, pt_tlwe_temp, plain_bits, pmsb, batch_size);

      accumulated_time += RECORD_TIME_END(start, stop);

      CUDA_CHECK_RETURN(cudaMemcpy(res, pt_res_lvl1, sizeof(TFHEpp::TLWE<Lvl1>)*batch_size, cudaMemcpyDeviceToHost));
    }
}
