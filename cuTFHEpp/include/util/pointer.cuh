#pragma once

namespace cuTFHEpp::util
{

  template<typename T>
    struct Pointer{
      T* h_data_ = nullptr;
      T* d_data_ = nullptr;

      template<typename... Args>
        Pointer(Args&&... args)
        {
          h_data_ = new T(std::forward<Args>(args)...);
          CUDA_CHECK_RETURN(cudaMalloc(&d_data_, sizeof(T)));
          CUDA_CHECK_RETURN(cudaMemcpy(d_data_, h_data_, sizeof(T), cudaMemcpyHostToDevice));
        }

      ~Pointer() {
        if (d_data_ != nullptr) CUDA_CHECK_RETURN(cudaFree(d_data_));
        d_data_ = nullptr;
        if (h_data_ != nullptr) delete h_data_;
        h_data_ = nullptr;
      }

      Pointer(const Pointer&) = delete;
      Pointer& operator=(const Pointer&) = delete;
      Pointer& operator=(Pointer&&) = delete;

      Pointer(Pointer&& other)
      {
        h_data_ = other.h_data_;
        other.h_data_ = nullptr;
        d_data_ = other.d_data_;
        other.d_data_ = nullptr;
      }

      template<typename U>
        Pointer<U>& safe_cast()
        {
          static_assert(T::template can_cast<U>());
          return reinterpret_cast<Pointer<U>&>(*this);
        }

      T* operator->() {
        return h_data_;
      }

      T& get() const {
        return *d_data_;
      }
    };
} // namespace cuTFHEpp::util
