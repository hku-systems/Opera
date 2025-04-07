#include <iostream>
#include <cmath>
#include <random>
#include <cstdio>
#include <cutfhe++.h>

using namespace std;
using namespace cuTFHEpp;

template<typename P>
__global__ void FFT_batch(
    const Context &context,
    TFHEpp::DecomposedPolynomial<P> *res,
    TFHEpp::DecomposedPolynomialInFD<P> *a,
    size_t batch_size)
{
  const unsigned int bid = gridDim.x * blockIdx.y + blockIdx.x;
  const unsigned int gdim = gridDim.x * gridDim.y;

  for (int n = bid; n < batch_size; n += gdim)
    TwistFFT<P>(context.get_fft_data<P>(), res[n], a[n]);
}

template<typename P>
__global__ void IFFT_batch(
    const Context &context,
    TFHEpp::DecomposedPolynomialInFD<P> *res,
    const TFHEpp::DecomposedPolynomial<P> *a,
    size_t batch_size)
{
  const unsigned int bid = gridDim.x * blockIdx.y + blockIdx.x;
  const unsigned int gdim = gridDim.x * gridDim.y;

  for (int n = bid; n < batch_size; n += gdim)
    TwistIFFT<P>(context.get_fft_data<P>(), res[n], a[n]);
}

template<typename P>
void TestIFFT(const util::Pointer<Context> &context, const size_t num_test)
{
  using T = typename P::T;

  random_device seed_gen;
  default_random_engine engine(seed_gen());
  uniform_int_distribution<T> Torusdist(0,
    std::is_same<P, Lvl1>::value ? UINT32_MAX : UINT64_MAX);

  TFHEpp::DecomposedPolynomial<P> *d_poly;
  TFHEpp::DecomposedPolynomialInFD<P> *d_polyfft;
  std::unique_ptr<TFHEpp::DecomposedPolynomialInFD<P>[]> polyfft_host = std::make_unique<TFHEpp::DecomposedPolynomialInFD<P>[]>(num_test);

  CUDA_CHECK_RETURN(cudaMallocManaged(&d_poly, sizeof(TFHEpp::DecomposedPolynomial<P>) * num_test));
  CUDA_CHECK_RETURN(cudaMallocManaged(&d_polyfft, sizeof(TFHEpp::DecomposedPolynomialInFD<P>) * num_test));

  for (int i = 0; i < num_test; i++) {
    TFHEpp::DecomposedPolynomial<P> poly;
    for (T &j : poly) j = Torusdist(engine);

    d_poly[i] = poly;
    TFHEpp::TwistIFFT<P>(polyfft_host[i], poly);
  }

  cudaEvent_t start, stop;
  RECORD_TIME_START(start, stop);
  IFFT_batch<P><<<GRID_DIM, BLOCK_DIM>>>(context.get(), d_polyfft, d_poly, num_test);
  double time_used = RECORD_TIME_END(start, stop);

  std::cout << "Lvl" << (std::is_same<P, Lvl1>::value ? "1" : "2")
    << " IFFT time: " << time_used << "ms" << std::endl;

  for (int i = 0; i < num_test; i++) {
    for (int j = 0; j < P::n; j++)
    {
      double maxDiff = std::is_same<P, Lvl1>::value ? 1 : 1 << 20;
      assert(fabs(polyfft_host[i][j] - d_polyfft[i][j]) <= maxDiff);
    }
  }

  cudaFree(d_poly);
  cudaFree(d_polyfft);
}

template<typename P>
void TestFFT(const util::Pointer<Context> &context, const size_t num_test)
{
  using T = typename P::T;

  random_device seed_gen;
  default_random_engine engine(seed_gen());
  uniform_real_distribution<double> Torusdist(0,
    std::is_same<P, Lvl1>::value ? UINT32_MAX : UINT64_MAX);

  TFHEpp::DecomposedPolynomial<P> *d_poly;
  TFHEpp::DecomposedPolynomialInFD<P> *d_polyfft;
  std::unique_ptr<TFHEpp::DecomposedPolynomial<P>[]> poly_host = std::make_unique<TFHEpp::DecomposedPolynomial<P>[]>(num_test);

  CUDA_CHECK_RETURN(cudaMallocManaged(&d_poly, sizeof(TFHEpp::DecomposedPolynomial<P>) * num_test));
  CUDA_CHECK_RETURN(cudaMallocManaged(&d_polyfft, sizeof(TFHEpp::DecomposedPolynomialInFD<P>) * num_test));

  for (int i = 0; i < num_test; i++) {
    TFHEpp::DecomposedPolynomialInFD<P> polyfft;
    for (double &j : polyfft) j = Torusdist(engine);

    d_polyfft[i] = polyfft;
    TFHEpp::TwistFFT<P>(poly_host[i], polyfft);
  }

  cudaEvent_t start, stop;
  RECORD_TIME_START(start, stop);
  FFT_batch<P><<<GRID_DIM, BLOCK_DIM>>>(context.get(), d_poly, d_polyfft, num_test);
  double time_used = RECORD_TIME_END(start, stop);

  std::cout << "Lvl" << (std::is_same<P, Lvl1>::value ? "1" : "2")
    << " FFT time: " << time_used << "ms" << std::endl;

  for (int i = 0; i < num_test; i++) {
    for (int j = 0; j < P::n; j++)
    {
      T maxDiff = std::is_same<P, Lvl1>::value ? 1 : 1 << 10;
      assert(abs(static_cast<typename std::make_signed<T>::type>(poly_host[i][j] - d_poly[i][j])) <= maxDiff);
    }
  }

  cudaFree(d_poly);
  cudaFree(d_polyfft);
}

int main( int argc, char** argv)
{
  cudaSetDevice(DEVICE_ID);
  util::Pointer<Context> context;

  constexpr size_t num_test = 1024;

  TestIFFT<Lvl1>(context, num_test);
  TestIFFT<Lvl2>(context, num_test);
  TestFFT<Lvl1>(context, num_test);
  TestFFT<Lvl2>(context, num_test);

  // auto array_1 = TableGen<Lvl1::n/2>();
  // for (int i = 0; i < Lvl1::n; i++) {
  //   std::cout << array_1[i] << ", ";
  // }
  //
  // std::cout << std::endl;
  //
  // auto array_2 = TwistGen<Lvl1::n>();
  // for (int i = 0; i < Lvl1::n; i++) {
  //   std::cout << array_2[i] << ", ";
  // }
  // std::cout << std::endl;
 
  return 0;
}
