#include <iostream>
#include <cmath>
#include <random>
#include <cstdio>
#include <cutfhe++.h>

using namespace cuTFHEpp;
using namespace cuTFHEpp::util;

template<typename LvlXY, typename LvlYZ,
  typename LvlX = LvlXY::domainP, typename LvlY = LvlXY::targetP, typename LvlZ = LvlYZ::targetP>
void TestGateBoostrapping(const Pointer<Context> &context, const TFHESecretKey &sk, const size_t num_test)
{
  static_assert(std::is_same<LvlY, typename LvlYZ::domainP>::value, "Invalid LvlY");

  std::random_device seed_gen;
  std::default_random_engine engine(seed_gen());
  std::uniform_int_distribution<uint32_t> binary(0, 1);

  using P = std::conditional_t<isLvlCover<LvlX, LvlZ>(), LvlX, LvlZ>;

  Pointer<BootstrappingData<LvlYZ>> bs_data(num_test);
  std::vector<Pointer<cuTLWE<P>>> tlwe_data;
  tlwe_data.reserve(2);
  for (size_t i = 0; i < 2; ++i) {
    tlwe_data.emplace_back(num_test);
  }

  TFHEpp::TLWE<LvlX> *d_tlwe = tlwe_data[0]->template get<LvlX>();
  TFHEpp::TLWE<LvlZ> *d_res = tlwe_data[1]->template get<LvlZ>();

  std::vector<TFHEpp::TLWE<LvlX>> tlwe(num_test);
  std::vector<TFHEpp::TLWE<LvlZ>> res(num_test);
  std::vector<bool> p(num_test);

  for (int test = 0; test < num_test; test++) {
    p[test] = binary(engine) > 0;
    tlwe[test] = TFHEpp::tlweSymEncrypt<LvlX>(p[test] ? LvlX::μ : -LvlX::μ, LvlX::α, sk.key.get<LvlX>());
  }

  CUDA_CHECK_RETURN(cudaMemcpy(d_tlwe, tlwe.data(), sizeof(TFHEpp::TLWE<LvlX>)*num_test, cudaMemcpyHostToDevice));

  cudaEvent_t start, stop;
  RECORD_TIME_START(start, stop);
  GateBootstrapping<LvlXY, LvlYZ>(context.get(), bs_data, d_res, d_tlwe, num_test);
  float time = RECORD_TIME_END(start, stop);
  CUDA_CHECK_ERROR();

  std::cout << std::fixed << "GateBootstrapping: " << time << "ms, per gate = " << time/num_test << "ms" << std::endl;

  CUDA_CHECK_RETURN(cudaMemcpy(res.data(), d_res, sizeof(TFHEpp::TLWE<LvlZ>)*num_test, cudaMemcpyDeviceToHost));

  for (int test = 0; test < num_test; test++) {
    bool p2 = TFHEpp::tlweSymDecrypt<LvlZ>(res[test], sk.key.get<LvlZ>());
    assert(p2 == p[test]);
  }
}

int main(int argc, char** argv)
{
  cudaSetDevice(DEVICE_ID);

  TFHESecretKey sk;
  TFHEEvalKey ek;

  load_keys<BootstrappingKeyFFTLvl01, BootstrappingKeyFFTLvl02,
    KeySwitchingKeyLvl10, KeySwitchingKeyLvl20>(sk, ek);
  // load_keys<BootstrappingKeyFFTLvl01, KeySwitchingKeyLvl10>(sk, ek);

  std::cout << "copy eval key to GPU" << std::endl;
  Pointer<Context> context(ek);
  std::cout << "eval key is copied to GPU" << std::endl;

  const size_t num_test = 82;

  TestGateBoostrapping<Lvl10,Lvl01>(context, sk, num_test);
  TestGateBoostrapping<Lvl20,Lvl02>(context, sk, num_test);

  return 0;
}
