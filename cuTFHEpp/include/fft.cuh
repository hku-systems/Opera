#pragma once

// This code was modified based on: https://github.com/virtualsecureplatform/FFHEE

#include <cmath>
#include <iostream>
#include <tfhe++.hpp>
#include "types.h"
#include "utils.cuh"

namespace cuTFHEpp
{
  template<typename P>
    struct FFTData
    {
      double *fft_twist_;
      double *fft_table_;

      FFTData()
      {
        const std::array<double,P::n> h_twist = TableGen(1);
        const std::array<double,P::n> h_table = TableGen(4);

        CUDA_CHECK_RETURN(cudaMalloc(&fft_twist_, P::n * sizeof(double)));
        CUDA_CHECK_RETURN(cudaMalloc(&fft_table_, P::n * sizeof(double)));
        CUDA_CHECK_RETURN(cudaMemcpy(fft_twist_, h_twist.data(), P::n * sizeof(double), cudaMemcpyHostToDevice));
        CUDA_CHECK_RETURN(cudaMemcpy(fft_table_, h_table.data(), P::n * sizeof(double), cudaMemcpyHostToDevice));
      }

      ~FFTData()
      {
        CUDA_CHECK_RETURN(cudaFree(fft_twist_));
        CUDA_CHECK_RETURN(cudaFree(fft_table_));
      }

      FFTData(const FFTData&) = delete;
      FFTData& operator=(const FFTData&) = delete;
      FFTData& operator=(FFTData&&) = delete;
      FFTData(FFTData&&) = delete;

      inline std::array<double,P::n> TableGen(uint32_t k)
      {
        std::array<double, P::n> table;
        for(uint32_t i = 0; i < P::n/2; i++)
        {
          table[i] = std::cos(k*i*M_PI/P::n);
          table[i+P::n/2] = std::sin(k*i*M_PI/P::n);
        }
        return table;
      }

      __host__ __device__ inline double *get_fft_twist() const { return fft_twist_; }

      __host__ __device__ inline double *get_fft_table() const { return fft_table_; }
    };

  template<uint32_t N>
    __device__ inline void ButterflyAdd(double* const a, double* const b){
      double& are = *a;
      double& aim = *(a+N);
      double& bre = *b;
      double& bim = *(b+N);

      const double tempre = are;
      are += bre;
      bre = tempre - bre;
      const double tempim = aim;
      aim += bim;
      bim = tempim - bim;
    }

  template <uint32_t Nbit, uint32_t stride, bool isinvert =true>
    __device__ inline void TwiddleMul(double* const a, const double* table,const int i,const int step){
      constexpr uint32_t N = 1<<Nbit;

      double& are = *a;
      double& aim = *(a+N);
      const double bre = table[stride*(1<<step)*i];
      const double bim = isinvert?table[stride*(1<<step)*i + N]:-table[stride*(1<<step)*i + N];

      const double aimbim = aim * bim;
      const double arebim = are * bim;
      are = are * bre - aimbim;
      aim = aim * bre + arebim;
    }

  template <uint32_t Nbit, bool isinvert =true>
    __device__ inline void Radix4TwiddleMul(double* const a){
      constexpr uint32_t N = 1<<Nbit;

      double& are = *a;
      double& aim = *(a+N);
      const double temp = are;
      are = aim;
      aim = temp;
      if constexpr(isinvert){
        are*=-1;
      }
      else{
        aim*=-1;
      }
    }

  template <uint32_t Nbit, bool isinvert =true>
    __device__ inline void Radix8TwiddleMulStrideOne(double* const a){
      constexpr uint32_t N = 1<<Nbit;

      double& are = *a;
      double& aim = *(a+N);
      const double aimbim = isinvert?aim:-aim;
      const double arebim = isinvert?are:-are;
      are = M_SQRT1_2 *(are - aimbim);
      aim = M_SQRT1_2 *(aim + arebim);
    }

  template <uint32_t Nbit, bool isinvert =true>
    __device__ inline void Radix8TwiddleMulStrideThree(double* const a){
      constexpr uint32_t N = 1<<Nbit;

      double& are = *a;
      double& aim = *(a+N);
      const double aimbim = isinvert?aim:-aim;
      const double arebim = isinvert?are:-are;
      are = M_SQRT1_2 *(-are - aimbim);
      aim = M_SQRT1_2 *(-aim + arebim);
    }

  template<typename P>
    __device__ inline void TwistMulDirect(typename P::T *res, double* const a, const double* twist){
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

#pragma unroll
      for (int i = tid; i < P::n / 2; i+=bdim) {
        const double aimbim = a[i + P::n / 2] * -twist[i + P::n / 2];
        const double arebim = a[i] * -twist[i + P::n / 2];

        if constexpr(std::is_same<P,Lvl1>::value)
        {
          res[i] = static_cast<int64_t>((a[i] * twist[i] - aimbim));
          res[i + P::n / 2] = static_cast<int64_t>((a[i + P::n / 2] * twist[i] + arebim));
        }
        else if constexpr(std::is_same<P,Lvl2>::value)
        {
          constexpr uint64_t valmask0 = 0x000FFFFFFFFFFFFFul;
          constexpr uint64_t valmask1 = 0x0010000000000000ul;
          constexpr uint16_t expmask0 = 0x07FFu;

          // const double aimbim = a[i + Lvl2::n / 2] * -twist[i + Lvl2::n / 2];
          // const double arebim = a[i] * -twist[i + Lvl2::n / 2];
          const double resdoublere = (a[i] * twist[i] - aimbim);
          const double resdoubleim = (a[i + Lvl2::n / 2] * twist[i] + arebim);
          const uint64_t resre = reinterpret_cast<const uint64_t&>(resdoublere);
          const uint64_t resim = reinterpret_cast<const uint64_t&>(resdoubleim);

          uint64_t val = (resre&valmask0)|valmask1; //mantissa on 53 bits
          uint16_t expo = (resre>>52)&expmask0; //exponent 11 bits
          // 1023 -> 52th pos -> 0th pos
          // 1075 -> 52th pos -> 52th pos
          int16_t trans = expo-1075;
          uint64_t val2 = trans>0?(val<<trans):(val>>-trans);
          res[i] = (resre>>63)?-val2:val2;

          val = (resim&valmask0)|valmask1; //mantissa on 53 bits
          expo = (resim>>52)&expmask0; //exponent 11 bits
          // 1023 -> 52th pos -> 0th pos
          // 1075 -> 52th pos -> 52th pos
          trans = expo-1075;
          val2 = trans>0?(val<<trans):(val>>-trans);
          res[i + Lvl2::n / 2] = (resim>>63)?-val2:val2;
        }
        else
          static_assert(TFHEpp::false_v<P>, "Undefined Type for TwistMulDirect");
      }
      __syncthreads();
    }

  template<typename P>
    __device__ inline void TwistMulInvert_inplace(double* res, const double *twist){
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

#pragma unroll
      for (int i = tid; i < P::n / 2; i+=bdim) {
        const double are = res[i];
        const double aim = res[i+P::n/2];
        const double aimbim = aim * twist[i + P::n / 2];
        const double arebim = are * twist[i + P::n / 2];
        res[i] = are * twist[i] - aimbim;
        res[i + P::n / 2] = aim * twist[i] + arebim;
      }
      __syncthreads();
    }

  template<typename P>
    __device__ inline void TwistMulInvert(double* const res, const typename P::T* a, const double *twist){
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

#pragma unroll
      for (int i = tid; i < P::n / 2; i+=bdim) {
        const double are = static_cast<double>(static_cast<typename std::make_signed<typename P::T>::type>(a[i]));
        const double aim = static_cast<double>(static_cast<typename std::make_signed<typename P::T>::type>(a[i+P::n/2]));
        const double aimbim = aim * twist[i + P::n / 2];
        const double arebim = are * twist[i + P::n / 2];
        res[i] = are * twist[i] - aimbim;
        res[i + P::n / 2] = aim * twist[i] + arebim;
      }
      __syncthreads();
    }

  template<class P>
    __device__ inline void FFT(double* const res, const double* table){
      constexpr uint32_t Nbit = P::nbit-1;
      constexpr uint32_t N = 1<<Nbit;
      constexpr int basebit  = 3;

      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      constexpr uint32_t flag = Nbit%basebit;
      switch(flag){
        case 0:
#pragma unroll
          for(int index=tid;index<N/8;index+=bdim){
            double* const res0 = &res[index*8];
            double* const res1 = res0+1;
            double* const res2 = res0+2;
            double* const res3 = res0+3;
            double* const res4 = res0+4;
            double* const res5 = res0+5;
            double* const res6 = res0+6;
            double* const res7 = res0+7;

            ButterflyAdd<N>(res0,res1);
            ButterflyAdd<N>(res2,res3);
            ButterflyAdd<N>(res4,res5);
            ButterflyAdd<N>(res6,res7);

            Radix4TwiddleMul<Nbit,false>(res3);
            Radix4TwiddleMul<Nbit,false>(res7);

            ButterflyAdd<N>(res0,res2);
            ButterflyAdd<N>(res1,res3);
            ButterflyAdd<N>(res4,res6);
            ButterflyAdd<N>(res5,res7);

            Radix8TwiddleMulStrideOne<Nbit,false>(res5);
            Radix4TwiddleMul<Nbit,false>(res6);
            Radix8TwiddleMulStrideThree<Nbit,false>(res7);

            ButterflyAdd<N>(res0,res4);
            ButterflyAdd<N>(res1,res5);
            ButterflyAdd<N>(res2,res6);
            ButterflyAdd<N>(res3,res7);
          }
          break;
        case 2:
#pragma unroll
          for(int index=tid;index<N/4;index+=bdim){
            double* const res0 = &res[index*4];
            double* const res1 = res0+1;
            double* const res2 = res0+2;
            double* const res3 = res0+3;

            ButterflyAdd<N>(res0,res1);
            ButterflyAdd<N>(res2,res3);

            Radix4TwiddleMul<Nbit,false>(res3);

            ButterflyAdd<N>(res0,res2);
            ButterflyAdd<N>(res1,res3);

          }
          break;
        case 1:
#pragma unroll
          for(int index=tid;index<N/2;index+=bdim){
            double* const res0 = &res[index*2];
            double* const res1 = res0+1;

            ButterflyAdd<N>(res0,res1);
          }
          break;
      }
      __syncthreads();

#pragma unroll
      for(int step = Nbit-(flag>0?flag:basebit)-basebit; step>=0; step-=basebit){
        const uint32_t size = 1<<(Nbit-step);
        const uint32_t elementmask = (size>>basebit)-1;

#pragma unroll
        for(int index=tid;index<(N>>basebit);index+=bdim){
          const uint32_t elementindex = index&elementmask;
          const uint32_t blockindex = (index - elementindex)>>(Nbit-step-basebit);

          double* const res0 = &res[blockindex*size+elementindex];
          double* const res1 = res0+size/8;
          double* const res2 = res0+2*size/8;
          double* const res3 = res0+3*size/8;
          double* const res4 = res0+4*size/8;
          double* const res5 = res0+5*size/8;
          double* const res6 = res0+6*size/8;
          double* const res7 = res0+7*size/8;

          TwiddleMul<Nbit,4,false>(res1,table,elementindex,step);
          TwiddleMul<Nbit,2,false>(res2,table,elementindex,step);
          TwiddleMul<Nbit,6,false>(res3,table,elementindex,step);
          TwiddleMul<Nbit,1,false>(res4,table,elementindex,step);
          TwiddleMul<Nbit,5,false>(res5,table,elementindex,step);
          TwiddleMul<Nbit,3,false>(res6,table,elementindex,step);
          TwiddleMul<Nbit,7,false>(res7,table,elementindex,step);

          ButterflyAdd<N>(res0,res1);
          ButterflyAdd<N>(res2,res3);
          ButterflyAdd<N>(res4,res5);
          ButterflyAdd<N>(res6,res7);

          Radix4TwiddleMul<Nbit,false>(res3);
          Radix4TwiddleMul<Nbit,false>(res7);

          ButterflyAdd<N>(res0,res2);
          ButterflyAdd<N>(res1,res3);
          ButterflyAdd<N>(res4,res6);
          ButterflyAdd<N>(res5,res7);

          Radix8TwiddleMulStrideOne<Nbit,false>(res5);
          Radix4TwiddleMul<Nbit,false>(res6);
          Radix8TwiddleMulStrideThree<Nbit,false>(res7);

          ButterflyAdd<N>(res0,res4);
          ButterflyAdd<N>(res1,res5);
          ButterflyAdd<N>(res2,res6);
          ButterflyAdd<N>(res3,res7);
        }
        __syncthreads();
      }
    }

  template<class P>
    __device__ inline void IFFT(double* const res, const double* table){
      constexpr uint32_t Nbit = P::nbit-1;
      constexpr uint32_t N = 1<<Nbit;
      constexpr uint32_t basebit  = 3;

      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

#pragma unroll
      for(int step = 0; step+basebit<Nbit; step+=basebit){
        const uint32_t size = 1<<(Nbit-step);
        const uint32_t elementmask = (size>>basebit)-1;

#pragma unroll
        for(int index=tid;index<(N>>basebit);index+=bdim){
          const uint32_t elementindex = index&elementmask;
          const uint32_t blockindex = (index - elementindex)>>(Nbit-step-basebit);

          double* const res0 = &res[blockindex*size+elementindex];
          double* const res1 = res0+size/8;
          double* const res2 = res0+2*size/8;
          double* const res3 = res0+3*size/8;
          double* const res4 = res0+4*size/8;
          double* const res5 = res0+5*size/8;
          double* const res6 = res0+6*size/8;
          double* const res7 = res0+7*size/8;

          ButterflyAdd<N>(res0,res4);
          ButterflyAdd<N>(res1,res5);
          ButterflyAdd<N>(res2,res6);
          ButterflyAdd<N>(res3,res7);

          Radix8TwiddleMulStrideOne<Nbit,true>(res5);
          Radix4TwiddleMul<Nbit,true>(res6);
          Radix8TwiddleMulStrideThree<Nbit,true>(res7);

          ButterflyAdd<N>(res0,res2);
          ButterflyAdd<N>(res1,res3);
          ButterflyAdd<N>(res4,res6);
          ButterflyAdd<N>(res5,res7);

          Radix4TwiddleMul<Nbit,true>(res3);
          Radix4TwiddleMul<Nbit,true>(res7);

          ButterflyAdd<N>(res0,res1);
          ButterflyAdd<N>(res2,res3);
          ButterflyAdd<N>(res4,res5);
          ButterflyAdd<N>(res6,res7);

          TwiddleMul<Nbit,4,true>(res1,table,elementindex,step);
          TwiddleMul<Nbit,2,true>(res2,table,elementindex,step);
          TwiddleMul<Nbit,6,true>(res3,table,elementindex,step);
          TwiddleMul<Nbit,1,true>(res4,table,elementindex,step);
          TwiddleMul<Nbit,5,true>(res5,table,elementindex,step);
          TwiddleMul<Nbit,3,true>(res6,table,elementindex,step);
          TwiddleMul<Nbit,7,true>(res7,table,elementindex,step);
        }
        __syncthreads();
      }

      constexpr uint32_t flag = Nbit%basebit;
      switch(flag){
        case 0:
#pragma unroll
          for(int index=tid;index<N/8;index+=bdim){
            double* const res0 = &res[index*8];
            double* const res1 = res0+1;
            double* const res2 = res0+2;
            double* const res3 = res0+3;
            double* const res4 = res0+4;
            double* const res5 = res0+5;
            double* const res6 = res0+6;
            double* const res7 = res0+7;

            ButterflyAdd<N>(res0,res4);
            ButterflyAdd<N>(res1,res5);
            ButterflyAdd<N>(res2,res6);
            ButterflyAdd<N>(res3,res7);

            Radix8TwiddleMulStrideOne<Nbit,true>(res5);
            Radix4TwiddleMul<Nbit,true>(res6);
            Radix8TwiddleMulStrideThree<Nbit,true>(res7);

            ButterflyAdd<N>(res0,res2);
            ButterflyAdd<N>(res1,res3);
            ButterflyAdd<N>(res4,res6);
            ButterflyAdd<N>(res5,res7);

            Radix4TwiddleMul<Nbit,true>(res3);
            Radix4TwiddleMul<Nbit,true>(res7);

            ButterflyAdd<N>(res0,res1);
            ButterflyAdd<N>(res2,res3);
            ButterflyAdd<N>(res4,res5);
            ButterflyAdd<N>(res6,res7);
          }
          break;
        case 2:
#pragma unroll
          for(int index=tid;index<N/4;index+=bdim){
            double* const res0 = &res[index*4];
            double* const res1 = res0+1;
            double* const res2 = res0+2;
            double* const res3 = res0+3;

            ButterflyAdd<N>(res0,res2);
            ButterflyAdd<N>(res1,res3);
            Radix4TwiddleMul<Nbit,true>(res3);

            ButterflyAdd<N>(res0,res1);
            ButterflyAdd<N>(res2,res3);
          }
          break;
        case 1:
#pragma unroll
          for(int index=tid;index<N/2;index+=bdim){
            double* const res0 = &res[index*2];
            double* const res1 = res0+1;

            ButterflyAdd<N>(res0,res1);
          }
          break;
      }
      __syncthreads();
    }

  template<class P>
    __device__ inline void ScaleFFT(double* const res, const double* table)
    {
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      constexpr double scale = 2.0/(P::n);

#pragma unroll
      for (int i = tid; i < P::n; i+=bdim) res[i] *= scale;
      __syncthreads();

      FFT<P>(res, table);
    }

  template<class P>
    __device__ inline void ScaleFFT(double* const res, const double* a, const double* table)
    {
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      constexpr double scale = 2.0/(P::n);

#pragma unroll
      for (int i = tid; i < P::n; i+=bdim) res[i] = a[i] * scale;
      __syncthreads();

      FFT<P>(res, table);
    }

  template<class P>
    __device__ inline void TwistFFT(
        const FFTData<P> &fft_data,
        TFHEpp::DecomposedPolynomial<P> &res,
        TFHEpp::DecomposedPolynomialInFD<P> &a)
    {
      ScaleFFT<P>(a.data(), fft_data.get_fft_table());
      TwistMulDirect<P>(res.data(), a.data(), fft_data.get_fft_twist());
    }

  template<class P>
    __device__ inline void TwistFFT(
        const FFTData<P> &fft_data,
        TFHEpp::DecomposedPolynomial<P> &res,
        const TFHEpp::DecomposedPolynomialInFD<P> &a,
        TFHEpp::DecomposedPolynomialInFD<P> &temp)
    {
      ScaleFFT<P>(temp.data(), a.data(), fft_data.get_fft_table());
      TwistMulDirect<P>(res.data(), temp.data(), fft_data.get_fft_twist());
    }

  template<class P>
    __device__ inline void TwistIFFT(
        const FFTData<P> &fft_data,
        TFHEpp::DecomposedPolynomialInFD<P> &res,
        const TFHEpp::DecomposedPolynomial<P> &a)
    {
      TwistMulInvert<P>(res.data(), a.data(), fft_data.get_fft_twist());
      IFFT<P>(res.data(), fft_data.get_fft_table());
    }

  template<class P>
    __device__ inline void TwistIFFT_inplace(
        const FFTData<P> &fft_data,
        TFHEpp::DecomposedPolynomialInFD<P> &a)
    {
      TwistMulInvert_inplace<P>(a.data(), fft_data.get_fft_twist());
      IFFT<P>(a.data(), fft_data.get_fft_table());
    }
} // namespace cuTFHEpp
