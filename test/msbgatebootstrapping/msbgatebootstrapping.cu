#include <opera.h>

using namespace std;
using namespace opera;
using namespace cuTFHEpp;
using namespace cuTFHEpp::util;

template<typename LvlXY, typename LvlYZ, bool result_type,
  typename LvlX = LvlXY::domainP, typename LvlY = LvlXY::targetP, typename LvlZ = LvlYZ::targetP>
void TestMSBGateBoostrapping(const Pointer<Context> &context, TFHESecretKey &sk, const size_t num_test)
{
  static_assert(std::is_same<LvlY, typename LvlYZ::domainP>::value, "Invalid LvlY");

  uint32_t plain_bits = 4;

  random_device seed_gen;
  default_random_engine engine(seed_gen());
  uniform_int_distribution<uint32_t> message(0, (1 << (plain_bits - 1) - 1));

  using P = std::conditional_t<isLvlCover<LvlX, LvlZ>(), LvlX, LvlZ>;

  uint32_t p = 1 << (plain_bits - 2);
  uint32_t scale_bits = std::numeric_limits<typename P::T>::digits - plain_bits - 1;
  // cout << "p = " << p << endl;
  TFHEpp::TLWE<LvlX> c = TFHEpp::tlweSymInt32Encrypt<LvlX>(p, LvlX::α, pow(2., scale_bits), sk.key.get<LvlX>());

  vector<uint32_t> array1(num_test), array2(num_test);
  for(uint32_t &p:array1) p = message(engine);
  for(uint32_t &p:array2) p = message(engine);

  TFHEpp::TLWE<LvlX> *tlwearray1 = (TFHEpp::TLWE<LvlX> *)malloc(sizeof(TFHEpp::TLWE<LvlX>)*num_test);
  TFHEpp::TLWE<LvlX> *tlwearray2 = (TFHEpp::TLWE<LvlX> *)malloc(sizeof(TFHEpp::TLWE<LvlX>)*num_test);
  TFHEpp::TLWE<LvlZ> *bootedtlwearray = (TFHEpp::TLWE<LvlZ> *)malloc(sizeof(TFHEpp::TLWE<LvlZ>)*num_test);

  for(int i = 0;i<num_test;i++) {
    tlwearray1[i] = TFHEpp::tlweSymInt32Encrypt<LvlX>(array1[i], LvlX::α, pow(2., scale_bits), sk.key.get<LvlX>());
    tlwearray2[i] = TFHEpp::tlweSymInt32Encrypt<LvlX>(array2[i], LvlX::α, pow(2., scale_bits), sk.key.get<LvlX>());

    for (size_t j = 0; j <= LvlX::k * LvlX::n; j++) {
      tlwearray1[i][j] = tlwearray2[i][j] - tlwearray1[i][j];
    }
  }

  Pointer<BootstrappingData<LvlYZ>> bs_data(num_test);
  std::vector<Pointer<cuTLWE<P>>> tlwe_data;
  tlwe_data.reserve(2);
  for (size_t i = 0; i < 2; ++i) {
    tlwe_data.emplace_back(num_test);
  }

  TFHEpp::TLWE<LvlX> *d_tlwe = tlwe_data[0]->template get<LvlX>();
  TFHEpp::TLWE<LvlZ> *d_res = tlwe_data[1]->template get<LvlZ>();

  CUDA_CHECK_RETURN(cudaMemcpy(d_tlwe, tlwearray1, sizeof(TFHEpp::TLWE<LvlX>)*num_test, cudaMemcpyHostToDevice));

  cudaEvent_t start, stop;
  RECORD_TIME_START(start, stop);
  MSBGateBootstrapping<LvlXY, LvlYZ, result_type>(context.get(), bs_data, d_res, d_tlwe, num_test);
  float et = RECORD_TIME_END(start, stop);
  CUDA_CHECK_ERROR();

  CUDA_CHECK_RETURN(cudaMemcpy(bootedtlwearray, d_res, sizeof(TFHEpp::TLWE<LvlZ>)*num_test, cudaMemcpyDeviceToHost));


  cout<<"Total Time:"<<et<<"ms"<<endl;
  cout<<"Per Gate:"<<et/num_test<<"ms"<<endl;

  for (int test = 0; test < num_test; test++) {
    int32_t diff = array2[test] - array1[test];
    bool greater = diff < 0;
    // cout << "====================" << test << endl;
    // cout << "p = p2 - p1 = " << array2[test] << " - " << array1[test] << " = " << array2[test] - array1[test] << endl;
    if constexpr (IS_LOGIC(result_type)) {
      // cout << "decrypted = " << tlweSymDecrypt<LvlZ>(bootedtlwearray[test], sk.key.get<LvlZ>()) << endl;
      assert(TFHEpp::tlweSymDecrypt<LvlZ>(bootedtlwearray[test], sk.key.get<LvlZ>()) == greater);
    }
    else {
      // cout << "decrypted32 = " << tlweSymInt32Decrypt<LvlZ>(bootedtlwearray[test], pow(2., 31), sk.key.get<LvlZ>()) << endl;
      assert(TFHEpp::tlweSymInt32Decrypt<LvlZ>(bootedtlwearray[test], pow(2., 31), sk.key.get<LvlZ>()) == greater);
    }
  }

  cout<<"PASS"<<endl;
  free(tlwearray1);
  free(tlwearray2);
  free(bootedtlwearray);
}

int main( int argc, char** argv)
{
  cudaSetDevice(DEVICE_ID);

  TFHESecretKey sk;
  TFHEEvalKey ek;

  // load_keys<BootstrappingKeyFFTLvl01, KeySwitchingKeyLvl10>(sk, ek);
  load_keys<BootstrappingKeyFFTLvl01, BootstrappingKeyFFTLvl02,
    KeySwitchingKeyLvl10, KeySwitchingKeyLvl20>(sk, ek);

  std::cout << "copy eval key to GPU" << std::endl;
  Pointer<Context> context(ek);
  std::cout << "eval key is copied to GPU" << std::endl;

  const size_t num_test = 82;

  TestMSBGateBoostrapping<Lvl10,Lvl01,ARITHMETIC>(context, sk, num_test);
  TestMSBGateBoostrapping<Lvl10,Lvl01,LOGIC>(context, sk, num_test);
  TestMSBGateBoostrapping<Lvl20,Lvl01,ARITHMETIC>(context, sk, num_test);
  TestMSBGateBoostrapping<Lvl20,Lvl01,LOGIC>(context, sk, num_test);
  TestMSBGateBoostrapping<Lvl20,Lvl02,LOGIC>(context, sk, num_test);
}
