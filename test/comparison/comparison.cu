#include <opera.h>

using namespace std;
using namespace cuTFHEpp;
using namespace cuTFHEpp::util;
using namespace opera;

template<typename P, bool result_type>
void TestComp(const Pointer<Context> &context, TFHESecretKey &sk, uint32_t plain_bits, uint32_t num_test)
{
  cout << "============ Testing Comparison ============" << endl;
  cout << "Plain bits : " << plain_bits
    << ", Result type : " << (IS_ARITHMETIC(result_type) ? "Arithmetic" : "Logic")
    << ", Lvl : " << (std::is_same<P, Lvl1>::value ? "1" : "2")
    << ", Num test : " << num_test << endl;
  std::random_device seed_gen;
  std::default_random_engine engine(seed_gen());

  uint32_t scale_bits;
  std::vector<uint32_t> error_time(5, 0);
  std::vector<double> comparison_time(5, 0.);

  std::uniform_int_distribution<typename P::T> message(0, (1 << (plain_bits - 1) - 1));
  scale_bits = std::numeric_limits<typename P::T>::digits - plain_bits - 1;
  vector<typename P::T> p0(num_test), p1(num_test);
  vector<TFHEpp::TLWE<P>> c0(num_test), c1(num_test);
  vector<vector<TLWELvl1>> cres(5, vector<TLWELvl1>(num_test));
  vector<vector<typename P::T>> res(5, vector<typename P::T>(num_test)),
    dres(5, vector<typename P::T>(num_test));

  using U = LvlXY<Lvl0, P>::T;
  Pointer<BootstrappingData<U>> bs_data(num_test);
  std::vector<Pointer<cuTLWE<P>>> tlwe_data;
  tlwe_data.reserve(4);
  for (size_t i = 0; i < 4; ++i) {
    tlwe_data.emplace_back(num_test);
  }

  for (int test = 0; test < num_test; test++)
  {
    p0[test] = message(engine);
    p1[test] = message(engine);
    res[0][test] = p0[test] > p1[test];
    res[1][test] = p0[test] >= p1[test];
    res[2][test] = p0[test] < p1[test];
    res[3][test] = p0[test] <= p1[test];
    res[4][test] = p0[test] == p1[test];
    c0[test] = TFHEpp::tlweSymInt32Encrypt<P>(p0[test], P::α, pow(2., scale_bits), sk.key.get<P>());
    c1[test] = TFHEpp::tlweSymInt32Encrypt<P>(p1[test], P::α, pow(2., scale_bits), sk.key.get<P>());
  }

  HomComp<U, GT, result_type>(context.get(), bs_data, tlwe_data.data(),
      cres[0].data(), c0.data(), c1.data(), plain_bits, num_test, comparison_time[0]);
  HomComp<U, GE, result_type>(context.get(), bs_data, tlwe_data.data(),
      cres[1].data(), c0.data(), c1.data(), plain_bits, num_test, comparison_time[1]);
  HomComp<U, LT, result_type>(context.get(), bs_data, tlwe_data.data(),
      cres[2].data(), c0.data(), c1.data(), plain_bits, num_test, comparison_time[2]);
  HomComp<U, LE, result_type>(context.get(), bs_data, tlwe_data.data(),
      cres[3].data(), c0.data(), c1.data(), plain_bits, num_test, comparison_time[3]);
  HomComp<U, EQ, result_type>(context.get(), bs_data, tlwe_data.data(),
      cres[4].data(), c0.data(), c1.data(), plain_bits, num_test, comparison_time[4]);

  for (int test = 0; test < num_test; test++)
  {
    for (int i = 0; i < 5; i++) {
      if constexpr (IS_ARITHMETIC(result_type))
        dres[i][test] = TFHEpp::tlweSymInt32Decrypt<Lvl1>(cres[i][test], pow(2., 31), sk.key.get<Lvl1>());
      else dres[i][test] = TFHEpp::tlweSymDecrypt<Lvl1>(cres[i][test], sk.key.get<Lvl1>());
      if (dres[i][test] != res[i][test]) error_time[i]++;
    }
  }

  string comp[5] = {"GT", "GE", "LT", "LE", "EQ"};

  for (int i = 0; i < 5; i++) {
    std::cout << comp[i] << " Error: " << std::setw(5) << error_time[i] << ","
       << " Per Comp Time: " << std::setw(10) << comparison_time[i] / num_test << " ms,"
       << " Total Time: " << std::setw(10) << comparison_time[i] << " ms" << std::endl;
  }
}

int main( int argc, char** argv)
{
  cudaSetDevice(0);
  TFHESecretKey sk;
  TFHEEvalKey ek;

  load_keys<BootstrappingKeyFFTLvl01, BootstrappingKeyFFTLvl02,
    KeySwitchingKeyLvl10, KeySwitchingKeyLvl20, KeySwitchingKeyLvl21>(sk, ek);

  cout << "copy eval key to GPU" << endl;
  Pointer<Context> context(ek);
  cout << "eval key is copied to GPU" << endl;

  const uint32_t num_test = 82;

  TestComp<Lvl1, ARITHMETIC>(context, sk, 4, num_test);
  TestComp<Lvl1, LOGIC>(context, sk, 4, num_test);

  TestComp<Lvl1, ARITHMETIC>(context, sk, 5, num_test);
  TestComp<Lvl1, LOGIC>(context, sk, 5, num_test);

  TestComp<Lvl1, ARITHMETIC>(context, sk, 9, num_test);
  TestComp<Lvl1, LOGIC>(context, sk, 9, num_test);

  TestComp<Lvl2, ARITHMETIC>(context, sk, 4, num_test);
  TestComp<Lvl2, LOGIC>(context, sk, 4, num_test);

  TestComp<Lvl2, ARITHMETIC>(context, sk, 8, num_test);
  TestComp<Lvl2, LOGIC>(context, sk, 8, num_test);

  TestComp<Lvl2, ARITHMETIC>(context, sk, 13, num_test);
  TestComp<Lvl2, LOGIC>(context, sk, 13, num_test);

  TestComp<Lvl2, ARITHMETIC>(context, sk, 18, num_test);
  TestComp<Lvl2, LOGIC>(context, sk, 18, num_test);

  TestComp<Lvl2, ARITHMETIC>(context, sk, 23, num_test);
  TestComp<Lvl2, LOGIC>(context, sk, 23, num_test);

  TestComp<Lvl2, ARITHMETIC>(context, sk, 28, num_test);
  TestComp<Lvl2, LOGIC>(context, sk, 28, num_test);

  TestComp<Lvl2, ARITHMETIC>(context, sk, 32, num_test);
  TestComp<Lvl2, LOGIC>(context, sk, 32, num_test);
}
