#include <opera.h>
#include <phantom.h>
#include <chrono>
#include <thread>
#include "data_q19.h"

using namespace cuTFHEpp;
using namespace opera;
using namespace std;

bool FAST_COMP = true;
bool CACHE_ENABLED = true;
bool NOCHECK = true;

/***
 * TPC-H Query 19 modified
  select
    sum(l_extendedprice* (1 - l_discount)) as revenue
  from
    lineitem,
    part
  where
    (
      p_partkey = l_partkey
      and p_brand = 'Brand#52'
      and p_container in ('SM CASE', 'SM BOX', 'SM PACK', 'SM PKG')
      and l_quantity >= 3 and l_quantity <= 3 + 10
      and p_size between 1 and 5
      and l_shipmode in ('AIR', 'AIR REG')
      and l_shipinstruct = 'DELIVER IN PERSON'
    )
    or
    (
      p_partkey = l_partkey
      and p_brand = 'Brand#43'
      and p_container in ('MED BAG', 'MED BOX', 'MED PKG', 'MED PACK')
      and l_quantity >= 12 and l_quantity <= 12 + 10
      and p_size between 1 and 10
      and l_shipmode in ('AIR', 'AIR REG')
      and l_shipinstruct = 'DELIVER IN PERSON'
    )
    or
    (
      p_partkey = l_partkey
      and p_brand = 'Brand#52'
      and p_container in ('LG CASE', 'LG BOX', 'LG PACK', 'LG PKG')
      and l_quantity >= 21 and l_quantity <= 21 + 10
      and p_size between 1 and 15
      and l_shipmode in ('AIR', 'AIR REG')
      and l_shipinstruct = 'DELIVER IN PERSON'
    );

    consider:
    l_partkey and p_partkey are in plaintext
*/

void predicate_evaluation(std::vector<std::vector<TLWELvl1>> &pred_cres,
                          std::vector<std::vector<uint32_t>> &pred_res,
                          std::vector<DataRecord> &data,
                          QueryRequest &query_data,
                          TFHESecretKey &sk,
                          TFHEEvalKey &ek,
                          size_t rows,
                          double &filter_time)
{
  cout << "copy eval key to GPU" << endl;
  Pointer<Context> context(ek);
  Context &ctx = context.get();
  cout << "eval key is copied to GPU" << endl;

  std::cout << "Predicate evaluation: " << std::endl;
  using P = Lvl2;

  // Encrypt database
  std::cout << "Encrypting Database..." << std::endl;
  std::vector<TLWELvl2> brand_ciphers(rows), container_ciphers(rows),
      quantity_ciphers(rows), size_ciphers(rows), shipmode_ciphers(rows),
      shipinstruct_ciphers(rows);
  for (size_t i = 0; i < rows; i++) {
    auto row_data = data[i];
    brand_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.brand().value, Lvl2::α,
        pow(2., row_data.brand().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    container_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.container().value, Lvl2::α,
        pow(2., row_data.container().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    quantity_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.quantity().value, Lvl2::α,
        pow(2., row_data.quantity().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    size_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.size().value, Lvl2::α,
        pow(2., row_data.size().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    shipmode_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.shipmode().value, Lvl2::α,
        pow(2., row_data.shipmode().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    shipinstruct_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.shipinstruct().value, Lvl2::α,
        pow(2., row_data.shipinstruct().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  } // end of encryption

  // Encrypt Predicate values
  std::cout << "Encrypting Predicate Values..." << std::endl;

  // check if the predicate is correct
  // pred_xxx[1,2,3]_res[rows]
  std::vector<uint32_t> pred_brand1_res(rows, 0), pred_container1_res(rows, 0),
      pred_quantity1_res(rows, 0), pred_size1_res(rows, 0), pred_shipmode1_res(rows, 0),
      pred_shipinstruct1_res(rows, 0);
  std::vector<uint32_t> pred_brand2_res(rows, 0), pred_container2_res(rows, 0),
      pred_quantity2_res(rows, 0), pred_size2_res(rows, 0), pred_shipmode2_res(rows, 0),
      pred_shipinstruct2_res(rows, 0);
  std::vector<uint32_t> pred_brand3_res(rows, 0), pred_container3_res(rows, 0),
      pred_quantity3_res(rows, 0), pred_size3_res(rows, 0), pred_shipmode3_res(rows, 0),
      pred_shipinstruct3_res(rows, 0);
  std::vector<uint32_t> pred_res1(rows, 0), pred_res2(rows, 0), pred_res3(rows, 0);
  auto groupby_num = 1;
  // pred_res[groupby_num][rows]
  pred_res.resize(groupby_num, std::vector<uint32_t>(rows, 1));
  pred_cres.resize(groupby_num, std::vector<TLWELvl1>(rows));

  // pred_part & pred_group
  for (size_t i = 0; i < rows; i++) {
    pred_brand1_res[i] = !!(data[i].brand().value == query_data.brand1().value);
    pred_container1_res[i] =
        !!(std::find(
               query_data.container1().begin(), query_data.container1().end(),
               data[i].container().value) != query_data.container1().end());
    pred_quantity1_res[i] =
        !!(data[i].quantity().value >= query_data.quantity1_low().value &&
           data[i].quantity().value <= query_data.quantity1_high().value);
    pred_size1_res[i] =
        !!(data[i].size().value >= query_data.size1_low().value &&
           data[i].size().value <= query_data.size1_high().value);
    pred_shipmode1_res[i] = !!(
        std::find(query_data.shipmode1().begin(), query_data.shipmode1().end(),
                  data[i].shipmode().value) != query_data.shipmode1().end());
    pred_shipinstruct1_res[i] =
        !!(data[i].shipinstruct().value == query_data.shipinstruct1().value);
    pred_res1[i] = pred_brand1_res[i] & pred_container1_res[i] &
                   pred_quantity1_res[i] & pred_size1_res[i] &
                   pred_shipmode1_res[i] & pred_shipinstruct1_res[i];

    pred_brand2_res[i] = !!(data[i].brand().value == query_data.brand2().value);
    pred_container2_res[i] =
        !!(std::find(
               query_data.container2().begin(), query_data.container2().end(),
               data[i].container().value) != query_data.container2().end());
    pred_quantity2_res[i] =
        !!(data[i].quantity().value >= query_data.quantity2_low().value &&
           data[i].quantity().value <= query_data.quantity2_high().value);
    pred_size2_res[i] =
        !!(data[i].size().value >= query_data.size2_low().value &&
           data[i].size().value <= query_data.size2_high().value);
    pred_shipmode2_res[i] = !!(
        std::find(query_data.shipmode2().begin(), query_data.shipmode2().end(),
                  data[i].shipmode().value) != query_data.shipmode2().end());
    pred_shipinstruct2_res[i] =
        !!(data[i].shipinstruct().value == query_data.shipinstruct2().value);
    pred_res2[i] = pred_brand2_res[i] & pred_container2_res[i] &
                   pred_quantity2_res[i] & pred_size2_res[i] &
                   pred_shipmode2_res[i] & pred_shipinstruct2_res[i];

    pred_brand3_res[i] = !!(data[i].brand().value == query_data.brand3().value);
    pred_container3_res[i] =
        !!(std::find(
               query_data.container3().begin(), query_data.container3().end(),
               data[i].container().value) != query_data.container3().end());
    pred_quantity3_res[i] =
        !!(data[i].quantity().value >= query_data.quantity3_low().value &&
           data[i].quantity().value <= query_data.quantity3_high().value);
    pred_size3_res[i] =
        !!(data[i].size().value >= query_data.size3_low().value &&
           data[i].size().value <= query_data.size3_high().value);
    pred_shipmode3_res[i] = !!(
        std::find(query_data.shipmode3().begin(), query_data.shipmode3().end(),
                  data[i].shipmode().value) != query_data.shipmode3().end());
    pred_shipinstruct3_res[i] =
        !!(data[i].shipinstruct().value == query_data.shipinstruct3().value);
    pred_res3[i] = pred_brand3_res[i] & pred_container3_res[i] &
                   pred_quantity3_res[i] & pred_size3_res[i] &
                   pred_shipmode3_res[i] & pred_shipinstruct3_res[i];
  }
  // pred_res
  for (size_t i = 0; i < groupby_num; i++) {
    for (size_t j = 0; j < rows; j++) {
      pred_res[i][j] = !!(pred_res1[j] || pred_res2[j] || pred_res3[j]);
    }
  }

  // Encrypt Predicates
  std::vector<TLWELvl2> pred_cipher_brand1(rows), pred_cipher_quantity1_low(rows),
      pred_cipher_quantity1_high(rows), pred_cipher_size1_low(rows), pred_cipher_size1_high(rows),
      pred_cipher_shipinstruct1(rows);
  std::vector<std::vector<TLWELvl2>> pred_cipher_container1, pred_cipher_shipmode1;

  std::vector<TLWELvl2> pred_cipher_brand2(rows), pred_cipher_quantity2_low(rows),
      pred_cipher_quantity2_high(rows), pred_cipher_size2_low(rows), pred_cipher_size2_high(rows),
      pred_cipher_shipinstruct2(rows);
  std::vector<std::vector<TLWELvl2>> pred_cipher_container2, pred_cipher_shipmode2;

  std::vector<TLWELvl2> pred_cipher_brand3(rows), pred_cipher_quantity3_low(rows),
      pred_cipher_quantity3_high(rows), pred_cipher_size3_low(rows), pred_cipher_size3_high(rows),
      pred_cipher_shipinstruct3(rows);
  std::vector<std::vector<TLWELvl2>> pred_cipher_container3, pred_cipher_shipmode3;

  // encrypt predicate part 1
  auto pred_cipher_brand1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.brand1().value, Lvl2::α,
      pow(2., data[0].brand().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  double quantity_scale = pow(2., data[0].quantity().scale_bits<Lvl2>());
  auto pred_cipher_quantity1_low_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.quantity1_low().value, Lvl2::α, quantity_scale,
      sk.key.get<Lvl2>());
  auto pred_cipher_quantity1_high_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.quantity1_high().value, Lvl2::α, quantity_scale,
      sk.key.get<Lvl2>());
  double size_scale = pow(2., data[0].size().scale_bits<Lvl2>());
  auto pred_cipher_size1_low_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.size1_low().value, Lvl2::α, size_scale, sk.key.get<Lvl2>());
  auto pred_cipher_size1_high_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.size1_high().value, Lvl2::α, size_scale, sk.key.get<Lvl2>());
  auto pred_cipher_shipinstruct1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.shipinstruct1().value, Lvl2::α,
      pow(2., data[0].shipinstruct().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  for (size_t i = 0; i < rows; i++) {
    pred_cipher_brand1[i] = pred_cipher_brand1_temp;
    pred_cipher_quantity1_low[i] = pred_cipher_quantity1_low_temp;
    pred_cipher_quantity1_high[i] = pred_cipher_quantity1_high_temp;
    pred_cipher_size1_low[i] = pred_cipher_size1_low_temp;
    pred_cipher_size1_high[i] = pred_cipher_size1_high_temp;
    pred_cipher_shipinstruct1[i] = pred_cipher_shipinstruct1_temp;
  }
  // encrypt group by part
  double container_scale = pow(2., data[0].container().scale_bits<Lvl2>());
  auto container_group1 = query_data.container1();
  pred_cipher_container1.resize(container_group1.size(), std::vector<TLWELvl2>(rows));
  for (size_t i = 0; i < container_group1.size(); i++) {
    auto pred_cipher_container1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        container_group1[i].value, Lvl2::α, container_scale, sk.key.get<Lvl2>());
    for (size_t j = 0; j < rows; j++) {
      pred_cipher_container1[i][j] = pred_cipher_container1_temp;
    }
  }
  double shipmode_scale = pow(2., data[0].shipmode().scale_bits<Lvl2>());
  auto shipmode_group1 = query_data.shipmode1();
  pred_cipher_shipmode1.resize(shipmode_group1.size(), std::vector<TLWELvl2>(rows));
  for (size_t i = 0; i < shipmode_group1.size(); i++) {
    auto pred_cipher_shipmode1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        shipmode_group1[i].value, Lvl2::α, shipmode_scale, sk.key.get<Lvl2>());
    for (size_t j = 0; j < rows; j++) {
      pred_cipher_shipmode1[i][j] = pred_cipher_shipmode1_temp;
    }
  }

  // encrypt predicate part 2
  auto pred_cipher_brand2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.brand2().value, Lvl2::α,
      pow(2., data[0].brand().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_quantity2_low_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.quantity2_low().value, Lvl2::α, quantity_scale,
      sk.key.get<Lvl2>());
  auto pred_cipher_quantity2_high_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.quantity2_high().value, Lvl2::α, quantity_scale,
      sk.key.get<Lvl2>());
  auto pred_cipher_size2_low_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(  
      query_data.size2_low().value, Lvl2::α, size_scale, sk.key.get<Lvl2>());
  auto pred_cipher_size2_high_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.size2_high().value, Lvl2::α, size_scale, sk.key.get<Lvl2>());
  auto pred_cipher_shipinstruct2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.shipinstruct2().value, Lvl2::α,
      pow(2., data[0].shipinstruct().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  for (size_t i = 0; i < rows; i++) {
    pred_cipher_brand2[i] = pred_cipher_brand2_temp;
    pred_cipher_quantity2_low[i] = pred_cipher_quantity2_low_temp;
    pred_cipher_quantity2_high[i] = pred_cipher_quantity2_high_temp;
    pred_cipher_size2_low[i] = pred_cipher_size2_low_temp;
    pred_cipher_size2_high[i] = pred_cipher_size2_high_temp;
    pred_cipher_shipinstruct2[i] = pred_cipher_shipinstruct2_temp;
  }
  auto container_group2 = query_data.container2();
  pred_cipher_container2.resize(container_group2.size(), std::vector<TLWELvl2>(rows));
  for (size_t i = 0; i < container_group2.size(); i++) {
    auto pred_cipher_container2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        container_group2[i].value, Lvl2::α, container_scale, sk.key.get<Lvl2>());
    for (size_t j = 0; j < rows; j++) {
      pred_cipher_container2[i][j] = pred_cipher_container2_temp;
    }
  }
  auto shipmode_group2 = query_data.shipmode2();
  pred_cipher_shipmode2.resize(shipmode_group2.size(), std::vector<TLWELvl2>(rows));
  for (size_t i = 0; i < shipmode_group2.size(); i++) {
    auto pred_cipher_shipmode2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        shipmode_group2[i].value, Lvl2::α, shipmode_scale, sk.key.get<Lvl2>());
    for (size_t j = 0; j < rows; j++) {
      pred_cipher_shipmode2[i][j] = pred_cipher_shipmode2_temp;
    }
  }

  // encrypt predicate part 3
  auto pred_cipher_brand3_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.brand3().value, Lvl2::α,
      pow(2., data[0].brand().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_quantity3_low_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.quantity3_low().value, Lvl2::α, quantity_scale,
      sk.key.get<Lvl2>());
  auto pred_cipher_quantity3_high_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.quantity3_high().value, Lvl2::α, quantity_scale,
      sk.key.get<Lvl2>());
  auto pred_cipher_size3_low_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.size3_low().value, Lvl2::α, size_scale, sk.key.get<Lvl2>());
  auto pred_cipher_size3_high_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.size3_high().value, Lvl2::α, size_scale, sk.key.get<Lvl2>());
  auto pred_cipher_shipinstruct3_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.shipinstruct3().value, Lvl2::α,
      pow(2., data[0].shipinstruct().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  for (size_t i = 0; i < rows; i++) {
    pred_cipher_brand3[i] = pred_cipher_brand3_temp;
    pred_cipher_quantity3_low[i] = pred_cipher_quantity3_low_temp;
    pred_cipher_quantity3_high[i] = pred_cipher_quantity3_high_temp;
    pred_cipher_size3_low[i] = pred_cipher_size3_low_temp;
    pred_cipher_size3_high[i] = pred_cipher_size3_high_temp;
    pred_cipher_shipinstruct3[i] = pred_cipher_shipinstruct3_temp;
  }
  auto container_group3 = query_data.container3();
  pred_cipher_container3.resize(container_group3.size(), std::vector<TLWELvl2>(rows));
  for (size_t i = 0; i < container_group3.size(); i++) {
    auto pred_cipher_container3_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        container_group3[i].value, Lvl2::α, container_scale, sk.key.get<Lvl2>());
    for (size_t j = 0; j < rows; j++) {
      pred_cipher_container3[i][j] = pred_cipher_container3_temp;
    }
  }
  auto shipmode_group3 = query_data.shipmode3();
  pred_cipher_shipmode3.resize(shipmode_group3.size(), std::vector<TLWELvl2>(rows));
  for (size_t i = 0; i < shipmode_group3.size(); i++) {
    auto pred_cipher_shipmode3_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        shipmode_group3[i].value, Lvl2::α, shipmode_scale, sk.key.get<Lvl2>());
    for (size_t j = 0; j < rows; j++) {
      pred_cipher_shipmode3[i][j] = pred_cipher_shipmode3_temp;
    }
  }

  // Predicate Evaluation
  std::cout << "Start Predicate Evaluation..." << std::endl;
  std::vector<TLWELvl1> pred_part1_cres(rows), pred_part2_cres(rows),
      pred_part3_cres(rows);
  auto brand_bits = data[0].brand().bits;
  auto quantity_bits = data[0].quantity().bits;
  auto size_bits = data[0].size().bits;
  auto shipinstruct_bits = data[0].shipinstruct().bits;
  auto container_bits = data[0].container().bits;
  auto shipmode_bits = data[0].shipmode().bits;

  // part 1
  std::vector<TLWELvl1> pred_brand1_cres(rows), pred_container1_cres(rows),
      pred_quantity1_cres(rows), pred_size1_cres(rows),
      pred_shipmode1_cres(rows), pred_shipinstruct1_cres(rows);
  // part 2
  std::vector<TLWELvl1> pred_brand2_cres(rows), pred_container2_cres(rows),
      pred_quantity2_cres(rows), pred_size2_cres(rows),
      pred_shipmode2_cres(rows), pred_shipinstruct2_cres(rows);
  // part 3
  std::vector<TLWELvl1> pred_brand3_cres(rows), pred_container3_cres(rows),
      pred_quantity3_cres(rows), pred_size3_cres(rows),
      pred_shipmode3_cres(rows), pred_shipinstruct3_cres(rows);

  Pointer<BootstrappingData<Lvl02>> pt_bs_data(rows);
  auto &pt_bs_data_lvl1 = pt_bs_data.template safe_cast<BootstrappingData<Lvl01>>();

  std::vector<Pointer<cuTLWE<Lvl2>>> tlwe_data;
  tlwe_data.reserve(4);
  for (size_t i = 0; i < 4; ++i) tlwe_data.emplace_back(rows);

  Pointer<cuTLWE<Lvl2>> *pt_tlwe_data = tlwe_data.data();
  Pointer<cuTLWE<Lvl1>> *pt_tlwe_data_lvl1 = &pt_tlwe_data->template safe_cast<cuTLWE<Lvl1>>();

  filter_time = 0;

  // part 1
  // p_brand = 'Brand#52'
  HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_brand1_cres.data(), brand_ciphers.data(), pred_cipher_brand1.data(),
      brand_bits, rows, filter_time);
  // p_container in ('SM CASE', 'SM BOX', 'SM PACK', 'SM PKG')
  std::vector<TLWELvl1> tmp_ciper(rows);
  bool init_container1 = false;
  for (auto &container_cipher : pred_cipher_container1) {
    if (!init_container1) {
      HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
        pred_container1_cres.data(), container_ciphers.data(), container_cipher.data(),
        container_bits, rows, filter_time);
      init_container1 = true;
    } else {
      HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
        tmp_ciper.data(), container_ciphers.data(), container_cipher.data(),
        container_bits, rows, filter_time);
      HomOR<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_container1_cres.data(), pred_container1_cres.data(), tmp_ciper.data(),
        rows, filter_time);
    }
  }
  // l_quantity >= 3 and l_quantity <= 3 + 10
  HomComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      tmp_ciper.data(), quantity_ciphers.data(), pred_cipher_quantity1_low.data(),
      quantity_bits, rows, filter_time);
  HomComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_quantity1_cres.data(), quantity_ciphers.data(), pred_cipher_quantity1_high.data(),
      quantity_bits, rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_quantity1_cres.data(), tmp_ciper.data(), pred_quantity1_cres.data(),
      rows, filter_time);
  // p_size between 1 and 5
  HomComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      tmp_ciper.data(), size_ciphers.data(), pred_cipher_size1_low.data(),
      size_bits, rows, filter_time);
  HomComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_size1_cres.data(), size_ciphers.data(), pred_cipher_size1_high.data(),
      size_bits, rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_size1_cres.data(), tmp_ciper.data(), pred_size1_cres.data(),
      rows, filter_time);
  // l_shipmode in ('AIR', 'AIR REG')
  bool init_shipmode1 = false;
  for (auto &shipmode_cipher : pred_cipher_shipmode1) {
    if (!init_shipmode1) {
      HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
        pred_shipmode1_cres.data(), shipmode_ciphers.data(), shipmode_cipher.data(),
        shipmode_bits, rows, filter_time);
      init_shipmode1 = true;
    } else {
      HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
        tmp_ciper.data(), shipmode_ciphers.data(), shipmode_cipher.data(),
        shipmode_bits, rows, filter_time);
      HomOR<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_shipmode1_cres.data(), pred_shipmode1_cres.data(), tmp_ciper.data(),
        rows, filter_time);
    }
  }
  // l_shipinstruct = 'DELIVER IN PERSON'
  HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_shipinstruct1_cres.data(), shipinstruct_ciphers.data(), pred_cipher_shipinstruct1.data(),
      shipinstruct_bits, rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part1_cres.data(), pred_brand1_cres.data(), pred_container1_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part1_cres.data(), pred_part1_cres.data(), pred_quantity1_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part1_cres.data(), pred_part1_cres.data(), pred_size1_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part1_cres.data(), pred_part1_cres.data(), pred_shipmode1_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part1_cres.data(), pred_part1_cres.data(), pred_shipinstruct1_cres.data(),
      rows, filter_time);

  // part 2
  // p_brand = 'Brand#43'
  HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_brand2_cres.data(), brand_ciphers.data(), pred_cipher_brand2.data(),
      brand_bits, rows, filter_time);
  // p_container in ('MED BAG', 'MED BOX', 'MED PKG', 'MED PACK')
  bool init_container2 = false;
  for (auto &container_cipher : pred_cipher_container2) {
    if (!init_container2) {
      HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
        pred_container2_cres.data(), container_ciphers.data(), container_cipher.data(),
        container_bits, rows, filter_time);
      init_container2 = true;
    } else {
      HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
        tmp_ciper.data(), container_ciphers.data(), container_cipher.data(),
        container_bits, rows, filter_time);
      HomOR<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_container2_cres.data(), pred_container2_cres.data(), tmp_ciper.data(),
        rows, filter_time);
    }
  }
  // l_quantity >= 12 and l_quantity <= 12 + 10
  HomComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      tmp_ciper.data(), quantity_ciphers.data(), pred_cipher_quantity2_low.data(),
      quantity_bits, rows, filter_time);
  HomComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_quantity2_cres.data(), quantity_ciphers.data(), pred_cipher_quantity2_high.data(),
      quantity_bits, rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_quantity2_cres.data(), tmp_ciper.data(), pred_quantity2_cres.data(),
      rows, filter_time);
  // p_size between 1 and 10
  HomComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      tmp_ciper.data(), size_ciphers.data(), pred_cipher_size2_low.data(),
      size_bits, rows, filter_time);
  HomComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_size2_cres.data(), quantity_ciphers.data(), pred_cipher_size2_high.data(),
      size_bits, rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_size2_cres.data(), tmp_ciper.data(), pred_size2_cres.data(),
      rows, filter_time);
  // l_shipmode in ('AIR', 'AIR REG')
  bool init_shipmode2 = false;
  for (auto &shipmode_cipher : pred_cipher_shipmode2) {
    if (!init_shipmode2) {
      HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
        pred_shipmode2_cres.data(), shipmode_ciphers.data(), shipmode_cipher.data(),
        shipmode_bits, rows, filter_time);
      init_shipmode2 = true;
    } else {
      HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
        tmp_ciper.data(), shipmode_ciphers.data(), shipmode_cipher.data(),
        shipmode_bits, rows, filter_time);
      HomOR<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_shipmode2_cres.data(), pred_shipmode2_cres.data(), tmp_ciper.data(),
        rows, filter_time);
    }
  }
  // l_shipinstruct = 'DELIVER IN PERSON'
  HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_shipinstruct2_cres.data(), shipinstruct_ciphers.data(), pred_cipher_shipinstruct2.data(),
      shipinstruct_bits, rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part2_cres.data(), pred_brand2_cres.data(), pred_container2_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part2_cres.data(), pred_part2_cres.data(), pred_quantity2_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part2_cres.data(), pred_part2_cres.data(), pred_size2_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part2_cres.data(), pred_part2_cres.data(), pred_shipmode2_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part2_cres.data(), pred_part2_cres.data(), pred_shipinstruct2_cres.data(),
      rows, filter_time);

  // part 3
  // p_brand = 'Brand#52'
  HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_brand3_cres.data(), brand_ciphers.data(), pred_cipher_brand3.data(),
      brand_bits, rows, filter_time);
  // p_container in ('LG CASE', 'LG BOX', 'LG PACK', 'LG PKG')
  bool init_container3 = false;
  for (auto &container_cipher : pred_cipher_container3) {
    if (!init_container3) {
      HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
        pred_container3_cres.data(), container_ciphers.data(), container_cipher.data(),
        container_bits, rows, filter_time);
      init_container3 = true;
    } else {
      HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
        tmp_ciper.data(), container_ciphers.data(), container_cipher.data(),
        container_bits, rows, filter_time);
      HomOR<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_container3_cres.data(), pred_container3_cres.data(), tmp_ciper.data(),
        rows, filter_time);
    }
  }
  // l_quantity >= 21 and l_quantity <= 21 + 10
  HomComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      tmp_ciper.data(), quantity_ciphers.data(), pred_cipher_quantity3_low.data(),
      quantity_bits, rows, filter_time);
  HomComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_quantity3_cres.data(), quantity_ciphers.data(), pred_cipher_quantity3_high.data(),
      quantity_bits, rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_quantity3_cres.data(), tmp_ciper.data(), pred_quantity3_cres.data(),
      rows, filter_time);
  // p_size between 1 and 15
  HomComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      tmp_ciper.data(), size_ciphers.data(), pred_cipher_size3_low.data(),
      size_bits, rows, filter_time);
  HomComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_size3_cres.data(), quantity_ciphers.data(), pred_cipher_size3_high.data(),
      size_bits, rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_size3_cres.data(), tmp_ciper.data(), pred_size3_cres.data(),
      rows, filter_time);
  // l_shipmode in ('AIR', 'AIR REG')
  bool init_shipmode3 = false;
  for (auto &shipmode_cipher : pred_cipher_shipmode3) {
    if (!init_shipmode3) {
      HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
        pred_shipmode3_cres.data(), shipmode_ciphers.data(), shipmode_cipher.data(),
        shipmode_bits, rows, filter_time);
      init_shipmode3 = true;
    } else {
      HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
        tmp_ciper.data(), shipmode_ciphers.data(), shipmode_cipher.data(),
        shipmode_bits, rows, filter_time);
      HomOR<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_shipmode3_cres.data(), pred_shipmode3_cres.data(), tmp_ciper.data(),
        rows, filter_time);
    }
  }
  // l_shipinstruct = 'DELIVER IN PERSON'
  HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_shipinstruct3_cres.data(), shipinstruct_ciphers.data(), pred_cipher_shipinstruct3.data(),
      shipinstruct_bits, rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part3_cres.data(), pred_brand3_cres.data(), pred_container3_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part3_cres.data(), pred_part3_cres.data(), pred_quantity3_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part3_cres.data(), pred_part3_cres.data(), pred_size3_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part3_cres.data(), pred_part3_cres.data(), pred_shipmode3_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part3_cres.data(), pred_part3_cres.data(), pred_shipinstruct3_cres.data(),
      rows, filter_time);

  // Combine parts 1, 2, and 3
  HomOR<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[0].data(), pred_part1_cres.data(), pred_part2_cres.data(),
      rows, filter_time);
  HomOR<ARITHMETIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[0].data(), pred_cres[0].data(), pred_part3_cres.data(),
      rows, filter_time);

  // check the results
  if (!NOCHECK) {
    std::vector<std::vector<uint32_t>> pred_cres_de(groupby_num,
                                                    std::vector<uint32_t>(rows));
    size_t error_time = 0;

    uint32_t rlwe_scale_bits = 29;
    for (size_t j = 0; j < groupby_num; j++)
      ari_rescale<Lvl10, Lvl01>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
          pred_cres[j].data(), pred_cres[j].data(), rlwe_scale_bits, rows);

    for (size_t i = 0; i < rows; i++)
      for (size_t j = 0; j < groupby_num; j++) {
        pred_cres_de[j][i] = TFHEpp::tlweSymInt32Decrypt<Lvl1>(
            pred_cres[j][i], pow(2., 29), sk.key.get<Lvl1>());
      }
    for (size_t i = 0; i < rows; i++)
      for (size_t j = 0; j < groupby_num; j++)
        error_time += (pred_cres_de[j][i] == pred_res[j][i]) ? 0 : 1;

    cout << "Predicate Error: " << error_time << std::endl;
  }

  std::cout << "Filter Time : " << filter_time << "ms" << std::endl;
}

void predicate_evaluation_cache(std::vector<std::vector<TLWELvl1>> &pred_cres,
                          std::vector<std::vector<uint32_t>> &pred_res,
                          std::vector<DataRecord> &data,
                          QueryRequest &query_data, TFHESecretKey &sk,
                          TFHEEvalKey &ek, CacheManager<Lvl1> &cm,
                          std::vector<std::vector<CacheFilter>> &filters,
                          std::vector<std::string> &filters_name,
                          std::vector<CacheMetadata<Lvl1::T>> &metas,
                          std::vector<std::vector<CacheFilter>> &gfilters,
                          std::vector<std::string> &gfilters_name,
                          std::vector<CacheMetadata<Lvl1::T>> &gmetas,
                          size_t rows,
                          double &filter_time,
                          double &tfhe_correction_time)
{
  cout << "copy eval key to GPU" << endl;
  Pointer<Context> context(ek);
  Context &ctx = context.get();
  cout << "eval key is copied to GPU" << endl;

  std::cout << "Predicate evaluation: " << std::endl;
  using P = Lvl2;

  // Encrypt database
  std::cout << "Encrypting Database..." << std::endl;
  std::vector<TLWELvl2> brand_ciphers(rows), container_ciphers(rows),
      quantity_ciphers(rows), size_ciphers(rows), shipmode_ciphers(rows),
      shipinstruct_ciphers(rows);
  for (size_t i = 0; i < rows; i++) {
    auto row_data = data[i];
    brand_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.brand().value, Lvl2::α,
        pow(2., row_data.brand().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    container_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.container().value, Lvl2::α,
        pow(2., row_data.container().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    quantity_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.quantity().value, Lvl2::α,
        pow(2., row_data.quantity().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    size_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.size().value, Lvl2::α,
        pow(2., row_data.size().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    shipmode_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.shipmode().value, Lvl2::α,
        pow(2., row_data.shipmode().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    shipinstruct_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.shipinstruct().value, Lvl2::α,
        pow(2., row_data.shipinstruct().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  } // end of encryption

  // Encrypt Predicate values
  std::cout << "Encrypting Predicate Values..." << std::endl;

  // check if the predicate is correct
  // pred_xxx[1,2,3]_res[rows]
  std::vector<uint32_t> pred_brand1_res(rows, 0), pred_container1_res(rows, 0),
      pred_quantity1_res(rows, 0), pred_size1_res(rows, 0), pred_shipmode1_res(rows, 0),
      pred_shipinstruct1_res(rows, 0);
  std::vector<uint32_t> pred_brand2_res(rows, 0), pred_container2_res(rows, 0),
      pred_quantity2_res(rows, 0), pred_size2_res(rows, 0), pred_shipmode2_res(rows, 0),
      pred_shipinstruct2_res(rows, 0);
  std::vector<uint32_t> pred_brand3_res(rows, 0), pred_container3_res(rows, 0),
      pred_quantity3_res(rows, 0), pred_size3_res(rows, 0), pred_shipmode3_res(rows, 0),
      pred_shipinstruct3_res(rows, 0);
  std::vector<uint32_t> pred_res1(rows, 0), pred_res2(rows, 0), pred_res3(rows, 0);
  auto groupby_num = 1;
  // pred_res[groupby_num][rows]
  pred_res.resize(groupby_num, std::vector<uint32_t>(rows, 1));
  pred_cres.resize(groupby_num, std::vector<TLWELvl1>(rows));

  // pred_part & pred_group
  for (size_t i = 0; i < rows; i++) {
    pred_brand1_res[i] = !!(data[i].brand().value == query_data.brand1().value);
    pred_container1_res[i] =
        !!(std::find(
               query_data.container1().begin(), query_data.container1().end(),
               data[i].container().value) != query_data.container1().end());
    pred_quantity1_res[i] =
        !!(data[i].quantity().value >= query_data.quantity1_low().value &&
           data[i].quantity().value <= query_data.quantity1_high().value);
    pred_size1_res[i] =
        !!(data[i].size().value >= query_data.size1_low().value &&
           data[i].size().value <= query_data.size1_high().value);
    pred_shipmode1_res[i] = !!(
        std::find(query_data.shipmode1().begin(), query_data.shipmode1().end(),
                  data[i].shipmode().value) != query_data.shipmode1().end());
    pred_shipinstruct1_res[i] =
        !!(data[i].shipinstruct().value == query_data.shipinstruct1().value);
    pred_res1[i] = pred_brand1_res[i] & pred_container1_res[i] &
                   pred_quantity1_res[i] & pred_size1_res[i] &
                   pred_shipmode1_res[i] & pred_shipinstruct1_res[i];

    pred_brand2_res[i] = !!(data[i].brand().value == query_data.brand2().value);
    pred_container2_res[i] =
        !!(std::find(
               query_data.container2().begin(), query_data.container2().end(),
               data[i].container().value) != query_data.container2().end());
    pred_quantity2_res[i] =
        !!(data[i].quantity().value >= query_data.quantity2_low().value &&
           data[i].quantity().value <= query_data.quantity2_high().value);
    pred_size2_res[i] =
        !!(data[i].size().value >= query_data.size2_low().value &&
           data[i].size().value <= query_data.size2_high().value);
    pred_shipmode2_res[i] = !!(
        std::find(query_data.shipmode2().begin(), query_data.shipmode2().end(),
                  data[i].shipmode().value) != query_data.shipmode2().end());
    pred_shipinstruct2_res[i] =
        !!(data[i].shipinstruct().value == query_data.shipinstruct2().value);
    pred_res2[i] = pred_brand2_res[i] & pred_container2_res[i] &
                   pred_quantity2_res[i] & pred_size2_res[i] &
                   pred_shipmode2_res[i] & pred_shipinstruct2_res[i];

    pred_brand3_res[i] = !!(data[i].brand().value == query_data.brand3().value);
    pred_container3_res[i] =
        !!(std::find(
               query_data.container3().begin(), query_data.container3().end(),
               data[i].container().value) != query_data.container3().end());
    pred_quantity3_res[i] =
        !!(data[i].quantity().value >= query_data.quantity3_low().value &&
           data[i].quantity().value <= query_data.quantity3_high().value);
    pred_size3_res[i] =
        !!(data[i].size().value >= query_data.size3_low().value &&
           data[i].size().value <= query_data.size3_high().value);
    pred_shipmode3_res[i] = !!(
        std::find(query_data.shipmode3().begin(), query_data.shipmode3().end(),
                  data[i].shipmode().value) != query_data.shipmode3().end());
    pred_shipinstruct3_res[i] =
        !!(data[i].shipinstruct().value == query_data.shipinstruct3().value);
    pred_res3[i] = pred_brand3_res[i] & pred_container3_res[i] &
                   pred_quantity3_res[i] & pred_size3_res[i] &
                   pred_shipmode3_res[i] & pred_shipinstruct3_res[i];
  }
  // pred_res
  for (size_t i = 0; i < groupby_num; i++) {
    for (size_t j = 0; j < rows; j++) {
      pred_res[i][j] = !!(pred_res1[j] || pred_res2[j] || pred_res3[j]);
    }
  }

  // ==== generate cache filters
  std::vector<Lvl1::T> data_quantity, data_size;
  std::cout << "Cache Filter Generation..." << std::endl;
  std::transform(data.begin(), data.end(), std::back_inserter(data_quantity),
                 [](DataRecord &d) { return d.quantity().value; });
  std::transform(data.begin(), data.end(), std::back_inserter(data_size),
                 [](DataRecord &d) { return d.size().value; });

  size_t pv = 0;
  // part 1
  // p_brand = 'Brand#52' (pred_brand1_res)
  cm.generate(filters_name[0], pred_brand1_res, metas[0]);
  // l_quantity >= 3
  cm.generate(filters_name[1], data_quantity, metas[1]);
  // l_quantity <= 3 + 10
  cm.generate(filters_name[2], data_quantity, metas[2]);
  // p_size >= 1
  cm.generate(filters_name[3], data_size, metas[3]);
  // p_size <= 5
  cm.generate(filters_name[4], data_size, metas[4]);
  // shipinstruct = 'DELIVER IN PERSON' (pred_shipinstruct1_res)
  cm.generate(filters_name[5], pred_shipinstruct1_res, metas[5]);
  // p_container in ('SM CASE', 'SM BOX', 'SM PACK', 'SM PKG') (pred_container1_res)
  cm.generate(filters_name[6], pred_container1_res, metas[6]);
  // l_shipmode in ('AIR', 'AIR REG') (pred_shipmode1_res)
  cm.generate(filters_name[7], pred_shipmode1_res, metas[7]);

  // part 2
  // p_brand = 'Brand#43' (pred_brand2_res)
  cm.generate(filters_name[8], pred_brand2_res, metas[8]);
  // l_quantity >= 12
  cm.generate(filters_name[9], data_quantity, metas[9]);
  // l_quantity <= 12 + 10
  cm.generate(filters_name[10], data_quantity, metas[10]);
  // p_size >= 1
  cm.generate(filters_name[11], data_size, metas[11]);
  // p_size <= 10
  cm.generate(filters_name[12], data_size, metas[12]);
  // shipinstruct = 'DELIVER IN PERSON' (pred_shipinstruct2_res)
  cm.generate(filters_name[13], pred_shipinstruct2_res, metas[13]);
  // p_container in ('MED BAG', 'MED BOX', 'MED PKG', 'MED PACK') (pred_container2_res)
  cm.generate(filters_name[14], pred_container2_res, metas[14]);
  // l_shipmode in ('AIR', 'AIR REG') (pred_shipmode2_res)
  cm.generate(filters_name[15], pred_shipmode2_res, metas[15]);

  // part 3
  // p_brand = 'Brand#52' (pred_brand3_res)
  cm.generate(filters_name[16], pred_brand3_res, metas[16]);
  // l_quantity >= 21
  cm.generate(filters_name[17], data_quantity, metas[17]);
  // l_quantity <= 21 + 10
  cm.generate(filters_name[18], data_quantity, metas[18]);
  // p_size >= 1
  cm.generate(filters_name[19], data_size, metas[19]);
  // p_size <= 15
  cm.generate(filters_name[20], data_size, metas[20]);
  // shipinstruct = 'DELIVER IN PERSON' (pred_shipinstruct3_res)
  cm.generate(filters_name[21], pred_shipinstruct3_res, metas[21]);
  // p_container in ('LG CASE', 'LG BOX', 'LG PACK', 'LG PKG') (pred_container3_res)
  cm.generate(filters_name[22], pred_container3_res, metas[22]);
  // l_shipmode in ('AIR', 'AIR REG') (pred_shipmode3_res)
  cm.generate(filters_name[23], pred_shipmode3_res, metas[23]);

  // ==== end of cache filter generation

  // Encrypt Predicates
  std::vector<TLWELvl2> pred_cipher_brand1(rows), pred_cipher_quantity1_low(rows),
      pred_cipher_quantity1_high(rows), pred_cipher_size1_low(rows), pred_cipher_size1_high(rows),
      pred_cipher_shipinstruct1(rows);
  std::vector<std::vector<TLWELvl2>> pred_cipher_container1, pred_cipher_shipmode1;

  std::vector<TLWELvl2> pred_cipher_brand2(rows), pred_cipher_quantity2_low(rows),
      pred_cipher_quantity2_high(rows), pred_cipher_size2_low(rows), pred_cipher_size2_high(rows),
      pred_cipher_shipinstruct2(rows);
  std::vector<std::vector<TLWELvl2>> pred_cipher_container2, pred_cipher_shipmode2;

  std::vector<TLWELvl2> pred_cipher_brand3(rows), pred_cipher_quantity3_low(rows),
      pred_cipher_quantity3_high(rows), pred_cipher_size3_low(rows), pred_cipher_size3_high(rows),
      pred_cipher_shipinstruct3(rows);
  std::vector<std::vector<TLWELvl2>> pred_cipher_container3, pred_cipher_shipmode3;

  // encrypt predicate part 1
  auto pred_cipher_brand1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.brand1().value, Lvl2::α,
      pow(2., data[0].brand().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  double quantity_scale = pow(2., data[0].quantity().scale_bits<Lvl2>());
  auto pred_cipher_quantity1_low_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.quantity1_low().value, Lvl2::α, quantity_scale,
      sk.key.get<Lvl2>());
  auto pred_cipher_quantity1_high_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.quantity1_high().value, Lvl2::α, quantity_scale,
      sk.key.get<Lvl2>());
  double size_scale = pow(2., data[0].size().scale_bits<Lvl2>());
  auto pred_cipher_size1_low_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.size1_low().value, Lvl2::α, size_scale, sk.key.get<Lvl2>());
  auto pred_cipher_size1_high_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.size1_high().value, Lvl2::α, size_scale, sk.key.get<Lvl2>());
  auto pred_cipher_shipinstruct1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.shipinstruct1().value, Lvl2::α,
      pow(2., data[0].shipinstruct().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  for (size_t i = 0; i < rows; i++) {
    pred_cipher_brand1[i] = pred_cipher_brand1_temp;
    pred_cipher_quantity1_low[i] = pred_cipher_quantity1_low_temp;
    pred_cipher_quantity1_high[i] = pred_cipher_quantity1_high_temp;
    pred_cipher_size1_low[i] = pred_cipher_size1_low_temp;
    pred_cipher_size1_high[i] = pred_cipher_size1_high_temp;
    pred_cipher_shipinstruct1[i] = pred_cipher_shipinstruct1_temp;
  }
  // encrypt group by part
  double container_scale = pow(2., data[0].container().scale_bits<Lvl2>());
  auto container_group1 = query_data.container1();
  pred_cipher_container1.resize(container_group1.size(), std::vector<TLWELvl2>(rows));
  for (size_t i = 0; i < container_group1.size(); i++) {
    auto pred_cipher_container1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        container_group1[i].value, Lvl2::α, container_scale, sk.key.get<Lvl2>());
    for (size_t j = 0; j < rows; j++) {
      pred_cipher_container1[i][j] = pred_cipher_container1_temp;
    }
  }
  double shipmode_scale = pow(2., data[0].shipmode().scale_bits<Lvl2>());
  auto shipmode_group1 = query_data.shipmode1();
  pred_cipher_shipmode1.resize(shipmode_group1.size(), std::vector<TLWELvl2>(rows));
  for (size_t i = 0; i < shipmode_group1.size(); i++) {
    auto pred_cipher_shipmode1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        shipmode_group1[i].value, Lvl2::α, shipmode_scale, sk.key.get<Lvl2>());
    for (size_t j = 0; j < rows; j++) {
      pred_cipher_shipmode1[i][j] = pred_cipher_shipmode1_temp;
    }
  }

  // encrypt predicate part 2
  auto pred_cipher_brand2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.brand2().value, Lvl2::α,
      pow(2., data[0].brand().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_quantity2_low_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.quantity2_low().value, Lvl2::α, quantity_scale,
      sk.key.get<Lvl2>());
  auto pred_cipher_quantity2_high_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.quantity2_high().value, Lvl2::α, quantity_scale,
      sk.key.get<Lvl2>());
  auto pred_cipher_size2_low_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(  
      query_data.size2_low().value, Lvl2::α, size_scale, sk.key.get<Lvl2>());
  auto pred_cipher_size2_high_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.size2_high().value, Lvl2::α, size_scale, sk.key.get<Lvl2>());
  auto pred_cipher_shipinstruct2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.shipinstruct2().value, Lvl2::α,
      pow(2., data[0].shipinstruct().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  for (size_t i = 0; i < rows; i++) {
    pred_cipher_brand2[i] = pred_cipher_brand2_temp;
    pred_cipher_quantity2_low[i] = pred_cipher_quantity2_low_temp;
    pred_cipher_quantity2_high[i] = pred_cipher_quantity2_high_temp;
    pred_cipher_size2_low[i] = pred_cipher_size2_low_temp;
    pred_cipher_size2_high[i] = pred_cipher_size2_high_temp;
    pred_cipher_shipinstruct2[i] = pred_cipher_shipinstruct2_temp;
  }
  auto container_group2 = query_data.container2();
  pred_cipher_container2.resize(container_group2.size(), std::vector<TLWELvl2>(rows));
  for (size_t i = 0; i < container_group2.size(); i++) {
    auto pred_cipher_container2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        container_group2[i].value, Lvl2::α, container_scale, sk.key.get<Lvl2>());
    for (size_t j = 0; j < rows; j++) {
      pred_cipher_container2[i][j] = pred_cipher_container2_temp;
    }
  }
  auto shipmode_group2 = query_data.shipmode2();
  pred_cipher_shipmode2.resize(shipmode_group2.size(), std::vector<TLWELvl2>(rows));
  for (size_t i = 0; i < shipmode_group2.size(); i++) {
    auto pred_cipher_shipmode2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        shipmode_group2[i].value, Lvl2::α, shipmode_scale, sk.key.get<Lvl2>());
    for (size_t j = 0; j < rows; j++) {
      pred_cipher_shipmode2[i][j] = pred_cipher_shipmode2_temp;
    }
  }

  // encrypt predicate part 3
  auto pred_cipher_brand3_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.brand3().value, Lvl2::α,
      pow(2., data[0].brand().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_quantity3_low_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.quantity3_low().value, Lvl2::α, quantity_scale,
      sk.key.get<Lvl2>());
  auto pred_cipher_quantity3_high_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.quantity3_high().value, Lvl2::α, quantity_scale,
      sk.key.get<Lvl2>());
  auto pred_cipher_size3_low_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.size3_low().value, Lvl2::α, size_scale, sk.key.get<Lvl2>());
  auto pred_cipher_size3_high_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.size3_high().value, Lvl2::α, size_scale, sk.key.get<Lvl2>());
  auto pred_cipher_shipinstruct3_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.shipinstruct3().value, Lvl2::α,
      pow(2., data[0].shipinstruct().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  for (size_t i = 0; i < rows; i++) {
    pred_cipher_brand3[i] = pred_cipher_brand3_temp;
    pred_cipher_quantity3_low[i] = pred_cipher_quantity3_low_temp;
    pred_cipher_quantity3_high[i] = pred_cipher_quantity3_high_temp;
    pred_cipher_size3_low[i] = pred_cipher_size3_low_temp;
    pred_cipher_size3_high[i] = pred_cipher_size3_high_temp;
    pred_cipher_shipinstruct3[i] = pred_cipher_shipinstruct3_temp;
  }
  auto container_group3 = query_data.container3();
  pred_cipher_container3.resize(container_group3.size(), std::vector<TLWELvl2>(rows));
  for (size_t i = 0; i < container_group3.size(); i++) {
    auto pred_cipher_container3_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        container_group3[i].value, Lvl2::α, container_scale, sk.key.get<Lvl2>());
    for (size_t j = 0; j < rows; j++) {
      pred_cipher_container3[i][j] = pred_cipher_container3_temp;
    }
  }
  auto shipmode_group3 = query_data.shipmode3();
  pred_cipher_shipmode3.resize(shipmode_group3.size(), std::vector<TLWELvl2>(rows));
  for (size_t i = 0; i < shipmode_group3.size(); i++) {
    auto pred_cipher_shipmode3_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        shipmode_group3[i].value, Lvl2::α, shipmode_scale, sk.key.get<Lvl2>());
    for (size_t j = 0; j < rows; j++) {
      pred_cipher_shipmode3[i][j] = pred_cipher_shipmode3_temp;
    }
  }

  // Predicate Evaluation
  std::cout << "Start Predicate Evaluation..." << std::endl;
  std::vector<TLWELvl1> pred_part1_cres(rows), pred_part2_cres(rows),
      pred_part3_cres(rows);
  auto brand_bits = data[0].brand().bits;
  auto quantity_bits = data[0].quantity().bits;
  auto size_bits = data[0].size().bits;
  auto shipinstruct_bits = data[0].shipinstruct().bits;
  auto container_bits = data[0].container().bits;
  auto shipmode_bits = data[0].shipmode().bits;

  // ==== find cache filters
  // predicates
  for (int i = 0; i < filters_name.size(); i++) {
    cm.find(filters_name[i], filters[i], metas[i]);
  }
  // ==== end of finding cache filters

  // part 1
  std::vector<TLWELvl1> pred_brand1_cres(rows), pred_container1_cres(rows),
      pred_quantity1_cres(rows), pred_size1_cres(rows),
      pred_shipmode1_cres(rows), pred_shipinstruct1_cres(rows);
  // part 2
  std::vector<TLWELvl1> pred_brand2_cres(rows), pred_container2_cres(rows),
      pred_quantity2_cres(rows), pred_size2_cres(rows),
      pred_shipmode2_cres(rows), pred_shipinstruct2_cres(rows);
  // part 3
  std::vector<TLWELvl1> pred_brand3_cres(rows), pred_container3_cres(rows),
      pred_quantity3_cres(rows), pred_size3_cres(rows),
      pred_shipmode3_cres(rows), pred_shipinstruct3_cres(rows);

  Pointer<BootstrappingData<Lvl02>> pt_bs_data(rows);
  auto &pt_bs_data_lvl1 = pt_bs_data.template safe_cast<BootstrappingData<Lvl01>>();

  std::vector<Pointer<cuTLWE<Lvl2>>> tlwe_data;
  tlwe_data.reserve(4);
  for (size_t i = 0; i < 4; ++i) tlwe_data.emplace_back(rows);

  Pointer<cuTLWE<Lvl2>> *pt_tlwe_data = tlwe_data.data();
  Pointer<cuTLWE<Lvl1>> *pt_tlwe_data_lvl1 = &pt_tlwe_data->template safe_cast<cuTLWE<Lvl1>>();

  filter_time = 0;

  // part 1
  // p_brand = 'Brand#52'
  HomFastComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_brand1_cres.data(), brand_ciphers.data(), pred_cipher_brand1.data(),
      brand_bits, metas[0].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[0], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_brand1_cres.data(), rows, tfhe_correction_time);
  // p_container in ('SM CASE', 'SM BOX', 'SM PACK', 'SM PKG')
  std::vector<TLWELvl1> tmp_ciper(rows);
  bool init_container1 = false;
  for (auto &container_cipher : pred_cipher_container1) {
    auto &container_metas = metas[6];
    bool container_operated1 = !!container_metas.get_density();
    if (container_operated1) {
      if (!init_container1) {
        HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
          pred_container1_cres.data(), container_ciphers.data(), container_cipher.data(),
          container_bits, rows, filter_time);
        init_container1 = true;
      } else {
        HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
          tmp_ciper.data(), container_ciphers.data(), container_cipher.data(),
          container_bits, rows, filter_time);
        HomOR<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
          pred_container1_cres.data(), pred_container1_cres.data(), tmp_ciper.data(),
          rows, filter_time);
      }
    } else {
      tfhe_correction(ctx, filters[6], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_container1_cres.data(), rows, tfhe_correction_time);
    }
  }
  // l_quantity >= 3 and l_quantity <= 3 + 10
  HomFastComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      tmp_ciper.data(), quantity_ciphers.data(), pred_cipher_quantity1_low.data(),
      quantity_bits, metas[1].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[1], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_quantity1_cres.data(), rows, tfhe_correction_time);
  HomFastComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_quantity1_cres.data(), quantity_ciphers.data(), pred_cipher_quantity1_high.data(),
      quantity_bits, metas[2].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[2], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_quantity1_cres.data(), rows, tfhe_correction_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_quantity1_cres.data(), tmp_ciper.data(), pred_quantity1_cres.data(),
      rows, filter_time);
  // p_size between 1 and 5
  HomFastComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      tmp_ciper.data(), size_ciphers.data(), pred_cipher_size1_low.data(),
      size_bits, metas[3].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[3], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_size1_cres.data(), rows, tfhe_correction_time);
  HomFastComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_size1_cres.data(), size_ciphers.data(), pred_cipher_size1_high.data(),
      size_bits, metas[4].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[4], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_size1_cres.data(), rows, tfhe_correction_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_size1_cres.data(), tmp_ciper.data(), pred_size1_cres.data(),
      rows, filter_time);
  // l_shipmode in ('AIR', 'AIR REG')
  bool init_shipmode1 = false;
  for (auto &shipmode_cipher : pred_cipher_shipmode1) {
    auto &shipmode_metas = metas[7];
    bool shipmode_operated1 = !!shipmode_metas.get_density();
    if (shipmode_operated1) {
      if (!init_shipmode1) {
        HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
          pred_shipmode1_cres.data(), shipmode_ciphers.data(), shipmode_cipher.data(),
          shipmode_bits, rows, filter_time);
        init_shipmode1 = true;
      } else {
        HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
          tmp_ciper.data(), shipmode_ciphers.data(), shipmode_cipher.data(),
          shipmode_bits, rows, filter_time);
        HomOR<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
          pred_shipmode1_cres.data(), pred_shipmode1_cres.data(), tmp_ciper.data(),
          rows, filter_time);
      }
    }
    else {
      tfhe_correction(ctx, filters[7], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_shipmode1_cres.data(), rows, tfhe_correction_time);
    }
  }
  // l_shipinstruct = 'DELIVER IN PERSON'
  HomFastComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_shipinstruct1_cres.data(), shipinstruct_ciphers.data(), pred_cipher_shipinstruct1.data(),
      shipinstruct_bits, metas[5].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[5], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_shipinstruct1_cres.data(), rows, tfhe_correction_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part1_cres.data(), pred_brand1_cres.data(), pred_container1_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part1_cres.data(), pred_part1_cres.data(), pred_quantity1_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part1_cres.data(), pred_part1_cres.data(), pred_size1_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part1_cres.data(), pred_part1_cres.data(), pred_shipmode1_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part1_cres.data(), pred_part1_cres.data(), pred_shipinstruct1_cres.data(),
      rows, filter_time);

  // part 2
  // p_brand = 'Brand#43'
  HomFastComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_brand2_cres.data(), brand_ciphers.data(), pred_cipher_brand2.data(),
      brand_bits, metas[8].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[8], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_brand2_cres.data(), rows, tfhe_correction_time);
  // p_container in ('MED BAG', 'MED BOX', 'MED PKG', 'MED PACK')
  bool init_container2 = false;
  for (auto &container_cipher : pred_cipher_container2) {
    auto &container_metas = metas[14];
    bool container_operated2 = !!container_metas.get_density();
    if (container_operated2) {
      if (!init_container2) {
        HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
          pred_container2_cres.data(), container_ciphers.data(), container_cipher.data(),
          container_bits, rows, filter_time);
        init_container2 = true;
      } else {
        HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
          tmp_ciper.data(), container_ciphers.data(), container_cipher.data(),
          container_bits, rows, filter_time);
        HomOR<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
          pred_container2_cres.data(), pred_container2_cres.data(), tmp_ciper.data(),
          rows, filter_time);
      }
    } else {
      tfhe_correction(ctx, filters[14], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_container2_cres.data(), rows, tfhe_correction_time);
    }
  }
  // l_quantity >= 12 and l_quantity <= 12 + 10
  HomFastComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      tmp_ciper.data(), quantity_ciphers.data(), pred_cipher_quantity2_low.data(),
      quantity_bits, metas[9].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[9], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_quantity2_cres.data(), rows, tfhe_correction_time);
  HomFastComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_quantity2_cres.data(), quantity_ciphers.data(), pred_cipher_quantity2_high.data(),
      quantity_bits, metas[10].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[10], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_quantity2_cres.data(), rows, tfhe_correction_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_quantity2_cres.data(), tmp_ciper.data(), pred_quantity2_cres.data(),
      rows, filter_time);
  // p_size between 1 and 10
  HomFastComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      tmp_ciper.data(), size_ciphers.data(), pred_cipher_size2_low.data(),
      size_bits, metas[11].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[11], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_size2_cres.data(), rows, tfhe_correction_time);
  HomFastComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_size2_cres.data(), quantity_ciphers.data(), pred_cipher_size2_high.data(),
      size_bits, metas[12].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[12], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_size2_cres.data(), rows, tfhe_correction_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_size2_cres.data(), tmp_ciper.data(), pred_size2_cres.data(),
      rows, filter_time);
  // l_shipmode in ('AIR', 'AIR REG')
  bool init_shipmode2 = false;
  for (auto &shipmode_cipher : pred_cipher_shipmode2) {
    auto &shipmode_metas = metas[15];
    bool shipmode_operated2 = !!shipmode_metas.get_density();
    if (shipmode_operated2) {
      if (!init_shipmode2) {
        HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
          pred_shipmode2_cres.data(), shipmode_ciphers.data(), shipmode_cipher.data(),
          shipmode_bits, rows, filter_time);
        init_shipmode2 = true;
      } else {
        HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
          tmp_ciper.data(), shipmode_ciphers.data(), shipmode_cipher.data(),
          shipmode_bits, rows, filter_time);
        HomOR<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
          pred_shipmode2_cres.data(), pred_shipmode2_cres.data(), tmp_ciper.data(),
          rows, filter_time);
      }
    } else {
      tfhe_correction(ctx, filters[15], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_shipmode2_cres.data(), rows, tfhe_correction_time);
    }
  }
  // l_shipinstruct = 'DELIVER IN PERSON'
  HomFastComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_shipinstruct2_cres.data(), shipinstruct_ciphers.data(), pred_cipher_shipinstruct2.data(),
      shipinstruct_bits, metas[13].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[13], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_shipinstruct2_cres.data(), rows, tfhe_correction_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part2_cres.data(), pred_brand2_cres.data(), pred_container2_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part2_cres.data(), pred_part2_cres.data(), pred_quantity2_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part2_cres.data(), pred_part2_cres.data(), pred_size2_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part2_cres.data(), pred_part2_cres.data(), pred_shipmode2_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part2_cres.data(), pred_part2_cres.data(), pred_shipinstruct2_cres.data(),
      rows, filter_time);

  // part 3
  // p_brand = 'Brand#52'
  HomFastComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_brand3_cres.data(), brand_ciphers.data(), pred_cipher_brand3.data(),
      brand_bits, metas[16].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[16], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_brand3_cres.data(), rows, tfhe_correction_time);
  // p_container in ('LG CASE', 'LG BOX', 'LG PACK', 'LG PKG')
  bool init_container3 = false;
  for (auto &container_cipher : pred_cipher_container3) {
    auto &container_metas = metas[22];
    bool container_operated3 = !!container_metas.get_density();
    if (container_operated3) {
      if (!init_container3) {
        HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
          pred_container3_cres.data(), container_ciphers.data(), container_cipher.data(),
          container_bits, rows, filter_time);
        init_container3 = true;
      } else {
        HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
          tmp_ciper.data(), container_ciphers.data(), container_cipher.data(),
          container_bits, rows, filter_time);
        HomOR<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
          pred_container3_cres.data(), pred_container3_cres.data(), tmp_ciper.data(),
          rows, filter_time);
      }
    } else {
      tfhe_correction(ctx, filters[22], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_container3_cres.data(), rows, tfhe_correction_time);
    }
  }
  // l_quantity >= 21 and l_quantity <= 21 + 10
  HomFastComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      tmp_ciper.data(), quantity_ciphers.data(), pred_cipher_quantity3_low.data(),
      quantity_bits, metas[17].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[17], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_quantity3_cres.data(), rows, tfhe_correction_time);
  HomFastComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_quantity3_cres.data(), quantity_ciphers.data(), pred_cipher_quantity3_high.data(),
      quantity_bits, metas[18].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[18], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_quantity3_cres.data(), rows, tfhe_correction_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_quantity3_cres.data(), tmp_ciper.data(), pred_quantity3_cres.data(),
      rows, filter_time);
  // p_size between 1 and 15
  HomFastComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      tmp_ciper.data(), size_ciphers.data(), pred_cipher_size3_low.data(),
      size_bits, metas[19].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[19], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_size3_cres.data(), rows, tfhe_correction_time);
  HomFastComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_size3_cres.data(), quantity_ciphers.data(), pred_cipher_size3_high.data(),
      size_bits, metas[20].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[20], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_size3_cres.data(), rows, tfhe_correction_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_size3_cres.data(), tmp_ciper.data(), pred_size3_cres.data(),
      rows, filter_time);
  // l_shipmode in ('AIR', 'AIR REG')
  bool init_shipmode3 = false;
  for (auto &shipmode_cipher : pred_cipher_shipmode3) {
    auto &shipmode_metas = metas[23];
    bool shipmode_operated3 = !!shipmode_metas.get_density();
    if (shipmode_operated3) {
      if (!init_shipmode3) {
        HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
          pred_shipmode3_cres.data(), shipmode_ciphers.data(), shipmode_cipher.data(),
          shipmode_bits, rows, filter_time);
        init_shipmode3 = true;
      } else {
        HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
          tmp_ciper.data(), shipmode_ciphers.data(), shipmode_cipher.data(),
          shipmode_bits, rows, filter_time);
        HomOR<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
          pred_shipmode3_cres.data(), pred_shipmode3_cres.data(), tmp_ciper.data(),
          rows, filter_time);
      }
    } else {
      tfhe_correction(ctx, filters[23], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_shipmode3_cres.data(), rows, tfhe_correction_time);
    }
  }
  // l_shipinstruct = 'DELIVER IN PERSON'
  HomFastComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_shipinstruct3_cres.data(), shipinstruct_ciphers.data(), pred_cipher_shipinstruct3.data(),
      shipinstruct_bits, metas[21].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[21], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_shipinstruct3_cres.data(), rows, tfhe_correction_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part3_cres.data(), pred_brand3_cres.data(), pred_container3_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part3_cres.data(), pred_part3_cres.data(), pred_quantity3_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part3_cres.data(), pred_part3_cres.data(), pred_size3_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part3_cres.data(), pred_part3_cres.data(), pred_shipmode3_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_part3_cres.data(), pred_part3_cres.data(), pred_shipinstruct3_cres.data(),
      rows, filter_time);

  // Combine parts 1, 2, and 3
  HomOR<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[0].data(), pred_part1_cres.data(), pred_part2_cres.data(),
      rows, filter_time);
  HomOR<ARITHMETIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[0].data(), pred_cres[0].data(), pred_part3_cres.data(),
      rows, filter_time);

  // check the results
  if (!NOCHECK) {
    std::vector<std::vector<uint32_t>> pred_cres_de(groupby_num,
                                                    std::vector<uint32_t>(rows));
    size_t error_time = 0;

    uint32_t rlwe_scale_bits = 29;
    for (size_t j = 0; j < groupby_num; j++)
      ari_rescale<Lvl10, Lvl01>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
          pred_cres[j].data(), pred_cres[j].data(), rlwe_scale_bits, rows);

    for (size_t i = 0; i < rows; i++)
      for (size_t j = 0; j < groupby_num; j++) {
        pred_cres_de[j][i] = TFHEpp::tlweSymInt32Decrypt<Lvl1>(
            pred_cres[j][i], pow(2., 29), sk.key.get<Lvl1>());
      }
    for (size_t i = 0; i < rows; i++)
      for (size_t j = 0; j < groupby_num; j++)
        error_time += (pred_cres_de[j][i] == pred_res[j][i]) ? 0 : 1;

    cout << "Predicate Error: " << error_time << std::endl;
  }

  std::cout << "Filter Time : " << filter_time << "ms" << std::endl;

}

void aggregation(std::vector<PhantomCiphertext> &result,
                 std::vector<std::vector<uint32_t>> &pred_res,
                 std::vector<DataRecord> &data,
                 size_t rows,
                 PhantomRLWE &rlwe,
                 double &aggregation_time) {

  std::cout << "Aggregation :" << std::endl;
  size_t groupby_num = result.size();
  uint64_t slots_count = rows;

  // Table for data, ciphertext, and aggregation results
  struct DataPack {
    std::vector<double> &data;
    PhantomCiphertext &cipher;
    std::vector<PhantomCiphertext> &sum;
  };

  // Filter result * data
  // original data
  std::vector<double> revenue_data(rows);
  // packed ciphertext
  PhantomCiphertext revenue_cipher;
  // sum result ciphertext
  std::vector<PhantomCiphertext> sum_revenue(groupby_num);
  std::vector<DataPack> table = {
    {revenue_data, revenue_cipher, sum_revenue}};

  for (size_t i = 0; i < rows; i++) {
    revenue_data[i] = data[i].revenue().value;
  }

  // convert data to ciphertext
  PhantomPlaintext t_plain;
  double qd =
      rlwe.parms.coeff_modulus()[result[0].coeff_modulus_size_ - 1].value();
  for (auto [_data_plaintext, _data_cipher, _sum_cipher] : table) {
    pack_encode(*rlwe.context, _data_plaintext, qd, t_plain, *rlwe.ckks_encoder);
    rlwe.secret_key->encrypt_symmetric(*rlwe.context, t_plain, _data_cipher, false);
  }

  std::cout << "Aggregating .." << std::endl;
  // filtering the data
  std::chrono::system_clock::time_point start, end;
  start = std::chrono::system_clock::now();
  for (size_t i = 0; i < groupby_num; ++i) {
    for (auto [_data_plaintext, _data_cipher, _sum_cipher] : table) {
      multiply_and_relinearize(*rlwe.context, result[i], _data_cipher, _sum_cipher[i],
                                     *rlwe.relin_keys);
      rescale_to_next_inplace(*rlwe.context, _sum_cipher[i]);
    }
  }
  cudaDeviceSynchronize();
  end = std::chrono::system_clock::now();
  aggregation_time =
      std::chrono::duration_cast<std::chrono::milliseconds>(end - start)
          .count();

  // sum to aggregation
  int logrow = log2(rows);
  PhantomCiphertext temp;
  start = std::chrono::system_clock::now();
  for (size_t i = 0; i < groupby_num; ++i) {
    for (size_t j = 0; j < logrow; j++) {
      size_t step = 1 << (logrow - j - 1);
      for (auto [_data_plaintext, _data_cipher, _sum_cipher] : table) {
        temp = _sum_cipher[i];
        rotate_vector_inplace(*rlwe.context, temp, step, *rlwe.galois_keys);
        add_inplace(*rlwe.context, _sum_cipher[i], temp);
      }
    }
  }
  end = std::chrono::system_clock::now();
  aggregation_time +=
      std::chrono::duration_cast<std::chrono::nanoseconds>(end - start)
          .count();
  aggregation_time /= 1000000;
  std::cout << "Aggregation Time: " << aggregation_time << " ms" << std::endl;

  if (!NOCHECK) {
    // Decrypt and check the result
    std::vector<double> agg_result(slots_count);
    for (size_t i = 0; i < groupby_num; ++i) {
      for (auto [_data_plaintext, _data_cipher, _sum_cipher] : table) {
        rlwe.secret_key->decrypt(*rlwe.context, _sum_cipher[i], t_plain);
        pack_decode(*rlwe.context, agg_result, t_plain, *rlwe.ckks_encoder);
        double plain_result = 0;
        for (size_t j = 0; j < rows; j++) {
          plain_result += _data_plaintext[j] * pred_res[i][j];
        }
        cout << "Plain_result/Encrypted query result: " << plain_result << "/"
             << agg_result[0] << endl;
      }
    }
  }
}

void query_evaluation(TFHESecretKey &sk, TFHEEvalKey &ek, size_t rows, std::vector<double> &time)
{
  cout << "===== Query Evaluation: " << rows << " rows =====" << endl;
  // Generate database
  vector<DataRecord> data(rows);
  QueryRequest query_data;
  std::vector<Lvl1::T> container_select = {0, 1, 2};
  std::vector<Lvl1::T> shipmode_select = {0, 1};
  for (size_t i = 0; i < rows; i++) {
    data[i].init(container_select, shipmode_select);
  }
  query_data.init(container_select, 4, shipmode_select, 2);

  PhantomRLWE rlwe(rows);

  if (!CACHE_ENABLED) {
    double filter_time, conversion_time, aggregation_time;
    std::vector<std::vector<TLWELvl1>> pred_cres;
    std::vector<std::vector<uint32_t>> pred_res;
    std::vector<PhantomCiphertext> results;

    predicate_evaluation(pred_cres, pred_res, data, query_data, sk, ek, rows, filter_time);
    rlwe.genLWE2RLWEGaloisKeys();
    conversion(results, pred_cres, pred_res, rlwe, sk, conversion_time, NOCHECK);
    rlwe.genGaloisKeys();
    aggregation(results, pred_res, data, rows, rlwe, aggregation_time);
    record_e2e_time(time, rows, filter_time, conversion_time, aggregation_time);
    return;
  }
  using T = Lvl1::T;
  CacheManager<Lvl1> cm(&sk, &ek, &rlwe, FAST_COMP);

  std::vector<std::string> filters_name = {
    "brand1", "quantity1", "quantity2", "size1", "size2",
    "shipinstruct1", "container1", "shipmode1",
    "brand2", "quantity1", "quantity2", "size1", "size2",
    "shipinstruct2", "container2", "shipmode2",
    "brand3", "quantity1", "quantity2", "size1", "size2",
    "shipinstruct3", "container3", "shipmode3"
  };
  std::vector<std::vector<CacheFilter>> filters(filters_name.size());
  std::vector<CacheMetadata<T>> metas = {
      // part 1
      CacheMetadata<T>(CompLogic::NE, (T)0),
      CacheMetadata<T>(CompLogic::GE, (T)query_data.quantity1_low().value),
      CacheMetadata<T>(CompLogic::LE, (T)query_data.quantity1_high().value),
      CacheMetadata<T>(CompLogic::GE, (T)query_data.size1_low().value),
      CacheMetadata<T>(CompLogic::LE, (T)query_data.size1_high().value),
      CacheMetadata<T>(CompLogic::NE, (T)0),
      CacheMetadata<T>(CompLogic::NE, (T)0),
      CacheMetadata<T>(CompLogic::NE, (T)0),
      // part 2
      CacheMetadata<T>(CompLogic::NE, (T)0),
      CacheMetadata<T>(CompLogic::GE, (T)query_data.quantity2_low().value),
      CacheMetadata<T>(CompLogic::LE, (T)query_data.quantity2_high().value),
      CacheMetadata<T>(CompLogic::GE, (T)query_data.size2_low().value),
      CacheMetadata<T>(CompLogic::LE, (T)query_data.size2_high().value),
      CacheMetadata<T>(CompLogic::NE, (T)0),
      CacheMetadata<T>(CompLogic::NE, (T)0),
      CacheMetadata<T>(CompLogic::NE, (T)0),
      // part 3
      CacheMetadata<T>(CompLogic::NE, (T)0),
      CacheMetadata<T>(CompLogic::GE, (T)query_data.quantity3_low().value),
      CacheMetadata<T>(CompLogic::LE, (T)query_data.quantity3_high().value),
      CacheMetadata<T>(CompLogic::GE, (T)query_data.size3_low().value),
      CacheMetadata<T>(CompLogic::LE, (T)query_data.size3_high().value),
      CacheMetadata<T>(CompLogic::NE, (T)0),
      CacheMetadata<T>(CompLogic::NE, (T)0),
      CacheMetadata<T>(CompLogic::NE, (T)0),
  };

  size_t _group_size = 0;
  std::vector<std::string> gfilters_name;
  std::vector<std::vector<CacheFilter>> gfilters(_group_size);
  std::vector<CacheMetadata<T>> gmetas;
  for (size_t i = 0; i < _group_size; ++i) {
    gfilters_name.push_back("");
    gmetas.push_back(CacheMetadata<T>());
  };

  double filter_time, conversion_time, tfhe_correction_time, ckks_correction_time, aggregation_time;
  std::vector<std::vector<TLWELvl1>> pred_cres;
  std::vector<std::vector<uint32_t>> pred_res;
  std::vector<PhantomCiphertext> results;
  predicate_evaluation_cache(pred_cres, pred_res, data, query_data, sk, ek,
      cm, filters, filters_name, metas, gfilters, gfilters_name, gmetas, rows, filter_time, tfhe_correction_time);
  rlwe.genLWE2RLWEGaloisKeys();
  conversion(results, pred_cres, pred_res, rlwe, sk, conversion_time, NOCHECK);
  rlwe.genGaloisKeys();
  filter_correction(results, pred_res, rlwe, filters, gfilters,
                  ckks_correction_time, NOCHECK);
  aggregation(results, pred_res, data, rows, rlwe, aggregation_time);

  record_e2e_time_cache(time, rows, filter_time, tfhe_correction_time, conversion_time, ckks_correction_time, aggregation_time);
}

int main(int argc, char** argv)
{
  argparse::ArgumentParser program("tpch_q19");

  add_arguments(program);

  try {
    program.parse_args(argc, argv);
  } catch (const std::exception &err) {
    std::cerr << err.what() << std::endl;
    std::cerr << program;
    return 1;
  }

  FAST_COMP = program["--nofastcomp"] == false;
  CACHE_ENABLED = program["--nocache"] == false;
  NOCHECK = program["--check"] == false;
  auto output = program.get<std::string>("-o");
  auto rows = program.get<std::vector<int>>("--rows");
  auto device = program.get<int>("-d");
  int n = rows.size();

  cudaSetDevice(device);
  TFHESecretKey sk;
  TFHEEvalKey ek;

  load_keys<BootstrappingKeyFFTLvl01, BootstrappingKeyFFTLvl02,
    KeySwitchingKeyLvl10, KeySwitchingKeyLvl20, KeySwitchingKeyLvl21>(sk, ek);

  std::vector<std::vector<double>> time(n, std::vector<double>());
  for (int i = 0; i < n; i++) {
    query_evaluation(sk, ek, rows[i], time[i]);
    phantom::util::global_pool()->Release();
  }

  output_result(output, time, CACHE_ENABLED);
}
