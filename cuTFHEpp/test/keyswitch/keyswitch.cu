#include <iostream>
#include <cmath>
#include <random>
#include <cstdio>
#include <cutfhe++.h>

using namespace cuTFHEpp;

template<typename LvlXY, typename LvlX = LvlXY::domainP, typename LvlY = LvlXY::targetP>
void TestKeySwitch(const util::Pointer<Context> &context, const TFHESecretKey &sk, const size_t num_test)
{
  std::random_device seed_gen;
  std::default_random_engine engine(seed_gen());
  std::uniform_int_distribution<uint32_t> binary(0, 1);

  TFHEpp::TLWE<LvlX> *d_tlwe;
  TFHEpp::TLWE<LvlY> *d_res;
  CUDA_CHECK_RETURN(cudaMallocManaged(&d_tlwe, sizeof(TFHEpp::TLWE<LvlX>) * num_test));
  CUDA_CHECK_RETURN(cudaMallocManaged(&d_res, sizeof(TFHEpp::TLWE<LvlY>) * num_test));
  std::vector<bool> p(num_test);

  for (int test = 0; test < num_test; test++) {
    p[test] = binary(engine) > 0;
    d_tlwe[test] = TFHEpp::tlweSymEncrypt<LvlX>(p[test] ? LvlX::μ : -LvlX::μ, LvlX::α, sk.key.get<LvlX>());
  }

  cudaEvent_t start, stop;
  RECORD_TIME_START(start, stop);
  IdentityKeySwitch<LvlXY><<<GRID_DIM, BLOCK_DIM>>>(context.get(), d_res, d_tlwe, num_test);
  float time = RECORD_TIME_END(start, stop);
  CUDA_CHECK_ERROR();

  std::cout << "IdentityKeySwitch: " << time << "ms" << std::endl;

  for (int test = 0; test < num_test; test++) {
    bool p2 = TFHEpp::tlweSymDecrypt<LvlY>(d_res[test], sk.key.get<LvlY>());
    assert(p2 == p[test]);
  }
}

int main(int argc, char** argv)
{
  cudaSetDevice(DEVICE_ID);

  TFHESecretKey sk;
  TFHEEvalKey ek;

  // load_keys<KeySwitchingKeyLvl21>(sk, ek);
  load_keys<KeySwitchingKeyLvl10, KeySwitchingKeyLvl20, KeySwitchingKeyLvl21>(sk, ek);

  std::cout << "copy eval key to GPU" << std::endl;
  util::Pointer<Context> context(ek);
  std::cout << "eval key is copied to GPU" << std::endl;

  const size_t num_test = 1024;

  TestKeySwitch<Lvl10>(context, sk, num_test);
  TestKeySwitch<Lvl20>(context, sk, num_test);
  TestKeySwitch<Lvl21>(context, sk, num_test);

  return 0;
}
