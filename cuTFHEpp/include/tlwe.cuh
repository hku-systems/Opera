#pragma once

namespace cuTFHEpp
{
  template<typename P>
  struct cuTLWE
  {
    using Lvl = P;

    TFHEpp::TLWE<P> *data;

    cuTLWE() : cuTLWE(1) {}

    cuTLWE(size_t batch_size)
    {
      CUDA_CHECK_RETURN(cudaMalloc(&data, batch_size * sizeof(TFHEpp::TLWE<P>)));
    }

    ~cuTLWE()
    {
      CUDA_CHECK_RETURN(cudaFree(data));
    }

    cuTLWE(const cuTLWE&) = delete;
    cuTLWE &operator=(const cuTLWE&) = delete;
    cuTLWE &operator=(cuTLWE&&) = delete;
    cuTLWE(cuTLWE&&) = delete;

    template<typename Lvl>
    __host__ __device__ inline TFHEpp::TLWE<Lvl>* get() const
    {
      static_assert(isLvlCover<P, Lvl>());
      return reinterpret_cast<TFHEpp::TLWE<Lvl>*>(data);
    }

    template<typename T, typename U = T::Lvl>
      static constexpr inline bool can_cast()
      {
        return isLvlCover<P, U>();
      }
  };
} // namespace cuTFHEpp
