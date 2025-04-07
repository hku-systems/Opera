#pragma once

namespace cuTFHEpp
{
  template<typename P>
    __device__ inline void SampleExtractIndex(
      TFHEpp::TLWE<P> &tlwe,
      const TFHEpp::TRLWE<P> &trlwe,
      const int index)
    {
      const unsigned int tid = blockDim.x*threadIdx.y+threadIdx.x;
      const unsigned int bdim = blockDim.x*blockDim.y;

      for (int i = tid; i < P::n; i += bdim)
      {
#pragma unroll
        for (int k = 0; k < P::k; k++)
          tlwe[k * P::n + i] = (i <= index) ? trlwe[k][index - i] : -trlwe[k][P::n + index - i];
      }

      if (tid == 0) tlwe[P::k * P::n] = trlwe[P::k][index];
    }
} // namespace cuTFHEpp
