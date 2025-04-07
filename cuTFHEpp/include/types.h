#pragma once

#include <tfhe++.hpp>

namespace cuTFHEpp
{
#define EXPLICIT_LVL_DOWN_DEFINE(P)       \
  P(1,0);                                 \
  P(2,0);                                 \
  P(2,1);
#define EXPLICIT_LVL_DOWN_EXTERN(P)       \
  extern P(1,0);                          \
  extern P(2,0);                          \
  extern P(2,1);
#define EXPLICIT_LVL_UP_DEFINE(P)         \
  P(0,1);                                 \
  P(0,2);
#define EXPLICIT_LVL_UP_EXTERN(P)         \
  extern P(0,1);                          \
  extern P(0,2);
#define EXPLICIT_LVL_DOWN_UP_DEFINE(P)    \
  P(1,0,1);                               \
  P(2,0,2);                               \
  P(2,0,1);
#define EXPLICIT_LVL_DOWN_UP_EXTERN(P)    \
  extern P(1,0,1);                        \
  extern P(2,0,2);                        \
  extern P(2,0,1);
#define EXPLICIT_LVL_DEFINE(P)            \
  P(1);                                   \
  P(2);
#define EXPLICIT_LVL_EXTERN(P)            \
  extern P(1);                            \
  extern P(2);

  using Lvl0 = TFHEpp::lvl0param;
  using Lvl1 = TFHEpp::lvl1param;
  using Lvl2 = TFHEpp::lvl2param;
  using Lvl01 = TFHEpp::lvl01param;
  using Lvl02 = TFHEpp::lvl02param;
  using Lvl10 = TFHEpp::lvl10param;
  using Lvl11 = TFHEpp::lvl11param;
  using Lvl20 = TFHEpp::lvl20param;
  using Lvl21 = TFHEpp::lvl21param;
  using Lvl22 = TFHEpp::lvl22param;
  using TLWELvl0 = TFHEpp::TLWE<Lvl0>;
  using TLWELvl1 = TFHEpp::TLWE<Lvl1>;
  using TLWELvl2 = TFHEpp::TLWE<Lvl2>;
  using TRLWELvl0 = TFHEpp::TRLWE<Lvl0>;
  using TRLWELvl1 = TFHEpp::TRLWE<Lvl1>;
  using TRLWELvl2 = TFHEpp::TRLWE<Lvl2>;
  using TRLWEInFDLvl1 = TFHEpp::TRLWEInFD<Lvl1>;
  using TRLWEInFDLvl2 = TFHEpp::TRLWEInFD<Lvl2>;
  using TFHEEvalKey = TFHEpp::EvalKey;
  using TFHESecretKey = TFHEpp::SecretKey;
  using TFHETLWE2TRLWEIKSKey11 = TFHEpp::TLWE2TRLWEIKSKey<TFHEpp::lvl11param>;
  using TFHETLWE2TRLWEIKSKey22 = TFHEpp::TLWE2TRLWEIKSKey<TFHEpp::lvl22param>;
  using PolynomialLvl1 = TFHEpp::Polynomial<Lvl1>;
  using PolynomialLvl2 = TFHEpp::Polynomial<Lvl2>;
  using DecomposedPolynomialLvl1 = TFHEpp::DecomposedPolynomial<Lvl1>;
  using DecomposedPolynomialLvl2 = TFHEpp::DecomposedPolynomial<Lvl2>;
  using DecomposedPolynomialInFDLvl1 = TFHEpp::DecomposedPolynomialInFD<Lvl1>;
  using DecomposedPolynomialInFDLvl2 = TFHEpp::DecomposedPolynomialInFD<Lvl2>;
  using BootstrappingKeyFFTLvl01 = TFHEpp::BootstrappingKeyFFT<Lvl01>;
  using BootstrappingKeyFFTLvl02 = TFHEpp::BootstrappingKeyFFT<Lvl02>;
  using KeySwitchingKeyLvl10 = TFHEpp::KeySwitchingKey<Lvl10>;
  using KeySwitchingKeyLvl20 = TFHEpp::KeySwitchingKey<Lvl20>;
  using KeySwitchingKeyLvl21 = TFHEpp::KeySwitchingKey<Lvl21>;

  template<typename X, typename Y>
  constexpr inline bool isLvlCover()
  {
    if constexpr(std::is_same_v<X, Lvl0>)
      if constexpr(std::is_same_v<Y, Lvl0>) return true;
    if constexpr(std::is_same_v<X, Lvl1>)
      if constexpr(std::is_same_v<Y, Lvl0> || std::is_same_v<Y, Lvl1>) return true;
    if constexpr(std::is_same_v<X, Lvl2>)
      if constexpr(std::is_same_v<Y, Lvl0> || std::is_same_v<Y, Lvl1> || std::is_same_v<Y, Lvl2>) return true;
    if constexpr(std::is_same_v<X, Lvl01>)
      if constexpr(std::is_same_v<Y, Lvl01>) return true;
    if constexpr(std::is_same_v<X, Lvl02>)
      if constexpr(std::is_same_v<Y, Lvl02> || std::is_same_v<Y, Lvl01>) return true;
    return false;
  }

  template<class X, class Y>
    struct LvlXY {
      using max = std::conditional_t<isLvlCover<X, Y>(), Y, X>;
      using min = std::conditional_t<isLvlCover<X, Y>(), X, Y>;
    };

  template<>
    struct LvlXY<Lvl0, Lvl1> { using T = Lvl01; };

  template<>
    struct LvlXY<Lvl0, Lvl2> { using T = Lvl02; };

  template<>
    struct LvlXY<Lvl1, Lvl0> { using T = Lvl10; };

  template<>
    struct LvlXY<Lvl2, Lvl0> { using T = Lvl20; };

  template<>
    struct LvlXY<Lvl2, Lvl1> { using T = Lvl21; };


  enum CompOp
  {
    EQ = 0,  // Equal
    GT,      // Greater than
    GE,      // Greater than or equal
    LT,      // Less than
    LE       // Less than or equal
  };
} // namespace cuTFHEpp
