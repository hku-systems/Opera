#pragma once

#include <iomanip>
#include "types.h"
#include "utils.cuh"
#include "cuparams.cuh"
#include "fft.cuh"
#include "trlwe.cuh"
#include "trgsw.cuh"
#include "keyswitch.cuh"
#include "util/pointer.cuh"

namespace cuTFHEpp
{
  template<typename LvlYZ, typename LvlY = LvlYZ::domainP, typename LvlZ = LvlYZ::targetP>
  struct BootstrappingData {
    using Lvl = LvlYZ;

    TFHEpp::TRLWE<LvlZ> *acc;
    TFHEpp::TRLWE<LvlZ> *temp;
    TFHEpp::TLWE<LvlY> *tlwe_from;
    TFHEpp::TRLWEInFD<LvlZ> *trlwefft;
    TFHEpp::Polynomial<LvlZ> *testvector;

    BootstrappingData() : BootstrappingData(1) {}

    BootstrappingData(size_t batch_size) {
      CUDA_CHECK_RETURN(cudaMalloc(&acc, batch_size * sizeof(TFHEpp::TRLWE<LvlZ>)));
      CUDA_CHECK_RETURN(cudaMalloc(&temp, batch_size * sizeof(TFHEpp::TRLWE<LvlZ>)));
      CUDA_CHECK_RETURN(cudaMalloc(&tlwe_from, batch_size * sizeof(TFHEpp::TLWE<LvlY>)));
      CUDA_CHECK_RETURN(cudaMalloc(&trlwefft, batch_size * sizeof(TFHEpp::TRLWEInFD<LvlZ>)));
      CUDA_CHECK_RETURN(cudaMalloc(&testvector, sizeof(TFHEpp::Polynomial<LvlZ>)));
    }

    ~BootstrappingData() {
      CUDA_CHECK_RETURN(cudaFree(acc));
      CUDA_CHECK_RETURN(cudaFree(temp));
      CUDA_CHECK_RETURN(cudaFree(tlwe_from));
      CUDA_CHECK_RETURN(cudaFree(trlwefft));
      CUDA_CHECK_RETURN(cudaFree(testvector));
    }

    template<typename T, typename U = T::Lvl>
      static constexpr inline bool can_cast()
      {
        return isLvlCover<LvlYZ, U>();
      }
  };

  template<typename LvlYZ, typename LvlY = LvlYZ::domainP, typename LvlZ = LvlYZ::targetP, uint32_t num_out = 1>
    __device__ inline void BlindRotate(
        const Context &context,
        double* shared_mem,
        TFHEpp::TLWE<LvlY> &tlwe,
        TFHEpp::TRLWE<LvlZ> &acc,
        TFHEpp::TRLWE<LvlZ> &temp,
        TFHEpp::TRLWEInFD<LvlZ> &trlwefft,
        TFHEpp::Polynomial<LvlZ> &testvector)
    {
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      TFHEpp::BootstrappingKeyFFT<LvlYZ> &bkfft = *context.get_bk<LvlYZ>();

      constexpr uint32_t bitwidth = TFHEpp::bits_needed<num_out - 1>();
      const uint32_t a0 = 2 * LvlZ::n -
        ((tlwe[LvlY::k * LvlY::n] >>
          (std::numeric_limits<typename LvlY::T>::digits - 1 - LvlZ::nbit + bitwidth))
         << bitwidth);

      for (int i = tid; i < LvlZ::n; i += bdim)
#pragma unroll
          for (int k = 0; k < LvlZ::k; k++) acc[k][i] = 0;

      PolynomialMulByXai<LvlZ>(acc[LvlZ::k], testvector, a0);
      __syncthreads();

      for (int index = 0; index < LvlY::k * LvlY::n; index++)
      {
        constexpr typename LvlY::T roundoffset =
          1ULL << (std::numeric_limits<typename LvlY::T>::digits - 2 -
              LvlZ::nbit);
        const uint32_t a =
          (tlwe[index] + roundoffset) >>
          (std::numeric_limits<typename LvlY::T>::digits - 1 -
           LvlZ::nbit);

        if (a == 0) continue;
#pragma unroll
        for (int k = 0; k < LvlZ::k + 1; k++)
            PolynomialMulByXaiMinusOne<LvlZ>(temp[k], acc[k], a);

        trgswfftExternalProduct<LvlZ>(context, shared_mem, temp, trlwefft, bkfft[index], a);

        for (int i = tid; i < LvlZ::n; i += bdim)
#pragma unroll
          for (int k = 0; k < LvlZ::k + 1; k++) acc[k][i] += temp[k][i];
        __syncthreads();
      }
    }

  template<typename LvlYZ, typename LvlY = LvlYZ::domainP, typename LvlZ = LvlYZ::targetP>
    __global__ void GateBootstrappingTLWE2TLWEFFT(
        const Context &context,
        BootstrappingData<LvlYZ> &bs_data,
        TFHEpp::TLWE<LvlZ> *res,
        const size_t batch_size)
    {
      __shared__ double shared_mem[LvlZ::n];

      const unsigned int bid = gridDim.x * blockIdx.y + blockIdx.x;
      const unsigned int gdim = gridDim.x * gridDim.y;

      for (int n = bid; n < batch_size; n += gdim) {
        TFHEpp::TLWE<LvlY> &tlwe = bs_data.tlwe_from[n];
        TFHEpp::TRLWE<LvlZ> &acc= bs_data.acc[n];
        TFHEpp::TRLWE<LvlZ> &temp = bs_data.temp[n];
        TFHEpp::TRLWEInFD<LvlZ> &trlwefft = bs_data.trlwefft[n];
        TFHEpp::Polynomial<LvlZ> &testvector = *bs_data.testvector;

        BlindRotate<LvlYZ>(context, shared_mem, tlwe, acc, temp, trlwefft, testvector);
        SampleExtractIndex<LvlZ>(res[n], acc, 0);
      }
    }

#define CUTFHEPP_GATE_BOOTSTRAPPING_TLWE2TLWEFFT(Y, Z)               \
  template __global__ void GateBootstrappingTLWE2TLWEFFT<Lvl##Y##Z>( \
      const Context &context,                                        \
      BootstrappingData<Lvl##Y##Z> &bs_data,                         \
      TFHEpp::TLWE<Lvl##Z> *res,                                     \
      size_t batch_size);

  EXPLICIT_LVL_UP_EXTERN(CUTFHEPP_GATE_BOOTSTRAPPING_TLWE2TLWEFFT);

  template<typename LvlXY, typename LvlYZ,
    typename LvlX = LvlXY::domainP, typename LvlY = LvlXY::targetP, typename LvlZ = LvlYZ::targetP>
  void GateBootstrapping(
      const Context &context,
      util::Pointer<BootstrappingData<LvlYZ>> &bs_data,
      TFHEpp::TLWE<LvlZ> *res,
      TFHEpp::TLWE<LvlX> *tlwe,
      const size_t batch_size)
  {
    static_assert(std::is_same<LvlY, typename LvlYZ::domainP>::value, "invalid LvlY");
    IdentityKeySwitch<LvlXY><<<GRID_DIM, BLOCK_DIM>>>(context, bs_data->tlwe_from, tlwe, batch_size);
    mu_polygen<LvlZ><<<1, BLOCK_DIM>>>(*bs_data->testvector, LvlZ::μ);
    constexpr size_t shared_mem_size = SHM_SIZE<LvlZ>;
    GateBootstrappingTLWE2TLWEFFT<LvlYZ><<<GRID_DIM, BLOCK_DIM, shared_mem_size>>>(context, bs_data.get(), res, batch_size);
  }

#define CUTFHEPP_GATE_BOOTSTRAPPING(X, Y, Z)                   \
  template void GateBootstrapping<Lvl##X##Y,Lvl##Y##Z>(        \
      const Context &context,                                  \
      util::Pointer<BootstrappingData<Lvl##Y##Z>> &bs_data,    \
      TFHEpp::TLWE<Lvl##Z> *res,                               \
      TFHEpp::TLWE<Lvl##X> *tlwe,                              \
      const size_t batch_size);

  EXPLICIT_LVL_DOWN_UP_EXTERN(CUTFHEPP_GATE_BOOTSTRAPPING);
} // namespace cuTFHEpp
