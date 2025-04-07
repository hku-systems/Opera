#include <opera.h>
#include <phantom.h>
#include <chrono>
#include <thread>
#include "data_q6.h"

using namespace cuTFHEpp;
using namespace opera;
using namespace std;

bool FAST_COMP = true;
bool CACHE_ENABLED = true;
bool NOCHECK = true;

/***
 * TPC-H Query 6
 * select
 sum(l_extendedprice * l_discount) as revenue
 from
 lineitem
 where
 l_shipdate >= date ':1'
 and l_shipdate < date ':1' + interval '1' year
 and l_discount between :2 - 0.01 and :2 + 0.01
 and l_quantity < :3;

 consider data \in [20200101~20221231]
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
  std::vector<TLWELvl2> shipdate_ciphers(rows), discount_ciphers(rows),
      quantity_ciphers(rows);
  for (size_t i = 0; i < rows; i++) {
    auto row_data = data[i];
    shipdate_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.shipdate().value, Lvl2::α,
        pow(2., row_data.shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    discount_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.discount().value, Lvl2::α,
        pow(2., row_data.discount().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    quantity_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.quantity().value, Lvl2::α,
        pow(2., row_data.quantity().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  }

  // Encrypt Predicate values
  std::cout << "Encrypting Predicate Values..." << std::endl;

  // check if the predicate is correct
  auto groupby_num = query_data.groupby_num();
  // pred_shipdate[rows]
  std::vector<uint32_t> pred_shipdate1_res(rows, 0);
  std::vector<uint32_t> pred_shipdate2_res(rows, 0);
  // pred_discount[rows]
  std::vector<uint32_t> pred_discount1_res(rows, 0);
  std::vector<uint32_t> pred_discount2_res(rows, 0);
  // pred_quantity[rows]
  std::vector<uint32_t> pred_quantity_res(rows, 0);
  // pred_res[groupby_num][rows]
  pred_res.resize(groupby_num, std::vector<uint32_t>(rows, 1));
  pred_cres.resize(groupby_num, std::vector<TLWELvl1>(rows));

  // pred_part
  for (size_t i = 0; i < rows; i++) {
    auto shipdate_low = query_data.shipdate1();
    auto shipdate_up = query_data.shipdate2();
    pred_shipdate1_res[i] = !!(data[i].shipdate().value >= shipdate_low.value);
    pred_shipdate2_res[i] = !!(data[i].shipdate().value < shipdate_up.value);
    auto discount_low = query_data.discount1();
    auto discount_up = query_data.discount2();
    pred_discount1_res[i] = !!(data[i].discount().value >= discount_low.value);
    pred_discount2_res[i] = !!(data[i].discount().value <= discount_up.value);

    pred_quantity_res[i] =
        !!((data[i].quantity().value < query_data.quantity().value));
    // pred_res
    pred_res[0][i] = !!(pred_shipdate1_res[i] & pred_shipdate2_res[i] &
                        pred_discount1_res[i] & pred_discount2_res[i] &
                        pred_quantity_res[i]);
  }

  // Encrypt Predicates
  std::vector<TLWELvl2> pred_cipher_shipdate1(rows), pred_cipher_shipdate2(rows),
    pred_cipher_discount1(rows), pred_cipher_discount2(rows),
    pred_cipher_quantity(rows);
  // encrypt predicate part
  auto pred_cipher_shipdate1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.shipdate1().value, Lvl2::α,
      pow(2., data[0].shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_shipdate2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.shipdate2().value, Lvl2::α,
      pow(2., data[0].shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_discount1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.discount1().value, Lvl2::α,
      pow(2., data[0].discount().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_discount2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.discount2().value, Lvl2::α,
      pow(2., data[0].discount().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_quantity_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.quantity().value, Lvl2::α,
      pow(2., data[0].quantity().scale_bits<Lvl2>()), sk.key.get<Lvl2>());

  for (size_t i = 0; i < rows; i++) {
    pred_cipher_shipdate1[i] = pred_cipher_shipdate1_temp;
    pred_cipher_shipdate2[i] = pred_cipher_shipdate2_temp;
    pred_cipher_discount1[i] = pred_cipher_discount1_temp;
    pred_cipher_discount2[i] = pred_cipher_discount2_temp;
    pred_cipher_quantity[i] = pred_cipher_quantity_temp;
  }

  // Predicate Evaluation
  std::cout << "Start Predicate Evaluation..." << std::endl;
  std::vector<TLWELvl1> pred_shipdate1_cres(rows), pred_shipdate2_cres(rows);
  std::vector<TLWELvl1> pred_discount1_cres(rows), pred_discount2_cres(rows);
  std::vector<TLWELvl1> pred_quantity_cres(rows);
  auto shipdate_bits = data[0].shipdate().bits;
  auto discount_bits = data[0].discount().bits;
  auto quantity_bits = data[0].quantity().bits;

  Pointer<BootstrappingData<Lvl02>> pt_bs_data(rows);
  auto &pt_bs_data_lvl1 = pt_bs_data.template safe_cast<BootstrappingData<Lvl01>>();

  std::vector<Pointer<cuTLWE<Lvl2>>> tlwe_data;
  tlwe_data.reserve(4);
  for (size_t i = 0; i < 4; ++i) tlwe_data.emplace_back(rows);

  Pointer<cuTLWE<Lvl2>> *pt_tlwe_data = tlwe_data.data();
  Pointer<cuTLWE<Lvl1>> *pt_tlwe_data_lvl1 = &pt_tlwe_data->template safe_cast<cuTLWE<Lvl1>>();

  filter_time = 0;

  HomComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_shipdate1_cres.data(), shipdate_ciphers.data(), pred_cipher_shipdate1.data(),
      shipdate_bits, rows, filter_time);
  HomComp<Lvl02, LT, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_shipdate2_cres.data(), shipdate_ciphers.data(), pred_cipher_shipdate2.data(),
      shipdate_bits, rows, filter_time);
  HomComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_discount1_cres.data(), discount_ciphers.data(), pred_cipher_discount1.data(),
      discount_bits, rows, filter_time);
  HomComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
     pred_discount2_cres.data(), discount_ciphers.data(), pred_cipher_discount2.data(),
     discount_bits, rows, filter_time);
  HomComp<Lvl02, LT, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_quantity_cres.data(), quantity_ciphers.data(), pred_cipher_quantity.data(),
      quantity_bits, rows, filter_time);

  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[0].data(), pred_shipdate1_cres.data(), pred_shipdate2_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[0].data(), pred_cres[0].data(), pred_discount1_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[0].data(), pred_cres[0].data(), pred_discount2_cres.data(),
      rows, filter_time);
  HomAND<ARITHMETIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[0].data(), pred_cres[0].data(), pred_quantity_cres.data(),
      rows, filter_time);

  // check the results
  if (!NOCHECK) {
    std::vector<std::vector<uint32_t>> pred_cres_de(groupby_num,
                                                    std::vector<uint32_t>(rows));
    std::vector<uint32_t> pred_shipdate1_cres_de(rows),
        pred_shipdate2_cres_de(rows);
    std::vector<uint32_t> pred_discount1_cres_de(rows),
        pred_discount2_cres_de(rows);
    std::vector<uint32_t> pred_quantity_cres_de(rows);
    for (size_t i = 0; i < rows; i++) {
      pred_shipdate1_cres_de[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_shipdate1_cres[i], sk.key.lvl1);
      pred_shipdate2_cres_de[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_shipdate2_cres[i], sk.key.lvl1);
      pred_discount1_cres_de[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_discount1_cres[i], sk.key.lvl1);
      pred_discount2_cres_de[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_discount2_cres[i], sk.key.lvl1);
      pred_quantity_cres_de[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_quantity_cres[i], sk.key.lvl1);
      if (pred_shipdate1_cres_de[i] != pred_shipdate1_res[i]) {
        std::cout << "Predicate shipdate1[" << i << "] Error: " << pred_shipdate1_cres_de[i]
                  << " " << pred_shipdate1_res[i] << std::endl;
      }
      if (pred_shipdate2_cres_de[i] != pred_shipdate2_res[i]) {
        std::cout << "Predicate shipdate2[" << i << "] Error: " << pred_shipdate2_cres_de[i]
                  << " " << pred_shipdate2_res[i] << std::endl;
      }
      if (pred_discount1_cres_de[i] != pred_discount1_res[i]) {
        std::cout << "Predicate discount1[" << i << "] Error: " << pred_discount1_cres_de[i]
                  << " " << pred_discount1_res[i] << std::endl;
      }
      if (pred_discount2_cres_de[i] != pred_discount2_res[i]) {
        std::cout << "Predicate discount2[" << i << "] Error: " << pred_discount2_cres_de[i]
                  << " " << pred_discount2_res[i] << std::endl;
      }
      if (pred_quantity_cres_de[i] != pred_quantity_res[i]) {
        std::cout << "Predicate quantity[" << i << "] Error: " << pred_quantity_cres_de[i]
                  << " " << pred_quantity_res[i] << std::endl;
      }
      pred_cres_de[0][i] = TFHEpp::tlweSymInt32Decrypt<Lvl1>(
          pred_cres[0][i], pow(2., 31), sk.key.get<Lvl1>());
    }

    size_t error_time = 0;

    uint32_t rlwe_scale_bits = 29;
    ari_rescale<Lvl10, Lvl01>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_cres[0].data(), pred_cres[0].data(), rlwe_scale_bits, rows);

    for (size_t i = 0; i < rows; i++)
      pred_cres_de[0][i] = TFHEpp::tlweSymInt32Decrypt<Lvl1>(
          pred_cres[0][i], pow(2., 29), sk.key.get<Lvl1>());
    for (size_t i = 0; i < rows; i++)
      error_time += (pred_cres_de[0][i] == pred_res[0][i]) ? 0 : 1;

    std::cout << "Predicate Error: " << error_time << std::endl;
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
  std::vector<TLWELvl2> shipdate_ciphers(rows), discount_ciphers(rows),
      quantity_ciphers(rows);
  for (size_t i = 0; i < rows; i++) {
    auto row_data = data[i];
    shipdate_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.shipdate().value, Lvl2::α,
        pow(2., row_data.shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    discount_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.discount().value, Lvl2::α,
        pow(2., row_data.discount().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    quantity_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.quantity().value, Lvl2::α,
        pow(2., row_data.quantity().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  }

  // Encrypt Predicate values
  std::cout << "Encrypting Predicate Values..." << std::endl;

  // check if the predicate is correct
  auto groupby_num = query_data.groupby_num();
  // pred_shipdate[rows]
  std::vector<uint32_t> pred_shipdate1_res(rows, 0);
  std::vector<uint32_t> pred_shipdate2_res(rows, 0);
  // pred_discount[rows]
  std::vector<uint32_t> pred_discount1_res(rows, 0);
  std::vector<uint32_t> pred_discount2_res(rows, 0);
  // pred_quantity[rows]
  std::vector<uint32_t> pred_quantity_res(rows, 0);
  // pred_res[groupby_num][rows]
  pred_res.resize(groupby_num, std::vector<uint32_t>(rows, 1));
  pred_cres.resize(groupby_num, std::vector<TLWELvl1>(rows));

  // pred_part
  auto shipdate_low = query_data.shipdate1().value;
  auto shipdate_up = query_data.shipdate2().value;
  auto discount_low = query_data.discount1().value;
  auto discount_up = query_data.discount2().value;
  auto quantity = query_data.quantity().value;
  std::vector<Lvl1::T> data_shipdate;
  std::vector<Lvl1::T> data_discount, data_quantity;
  // ==== generate cache filters
  std::transform(data.begin(), data.end(), std::back_inserter(data_shipdate),
                 [](DataRecord &item) { return item.shipdate().value; });
  std::transform(data.begin(), data.end(), std::back_inserter(data_discount),
                 [](DataRecord &item) { return item.discount().value; });
  std::transform(data.begin(), data.end(), std::back_inserter(data_quantity),
                 [](DataRecord &item) { return item.quantity().value; });
  cm.generate(filters_name[0], data_shipdate, metas[0]);
  cm.generate(filters_name[1], data_shipdate, metas[1]);
  cm.generate(filters_name[2], data_discount, metas[2]);
  cm.generate(filters_name[3], data_discount, metas[3]);
  cm.generate(filters_name[4], data_quantity, metas[4]);
  // ==== end of cache filter generation
  for (size_t i = 0; i < rows; i++) {
    pred_shipdate1_res[i] = !!(data_shipdate[i] >= shipdate_low);
    pred_shipdate2_res[i] = !!(data_shipdate[i] < shipdate_up);
    pred_discount1_res[i] = !!(data_discount[i] >= discount_low);
    pred_discount2_res[i] = !!(data_discount[i] <= discount_up);
    pred_quantity_res[i] = !!((data_quantity[i] < quantity));
    // pred_res
    pred_res[0][i] = !!(pred_shipdate1_res[i] & pred_shipdate2_res[i] &
                        pred_discount1_res[i] & pred_discount2_res[i] &
                        pred_quantity_res[i]);
  }

  // Encrypt Predicates
  std::vector<TLWELvl2> pred_cipher_shipdate1(rows), pred_cipher_shipdate2(rows),
    pred_cipher_discount1(rows), pred_cipher_discount2(rows),
    pred_cipher_quantity(rows);
  // encrypt predicate part
  auto pred_cipher_shipdate1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.shipdate1().value, Lvl2::α,
      pow(2., data[0].shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_shipdate2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.shipdate2().value, Lvl2::α,
      pow(2., data[0].shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_discount1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.discount1().value, Lvl2::α,
      pow(2., data[0].discount().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_discount2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.discount2().value, Lvl2::α,
      pow(2., data[0].discount().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_quantity_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.quantity().value, Lvl2::α,
      pow(2., data[0].quantity().scale_bits<Lvl2>()), sk.key.get<Lvl2>());

  for (size_t i = 0; i < rows; i++) {
    pred_cipher_shipdate1[i] = pred_cipher_shipdate1_temp;
    pred_cipher_shipdate2[i] = pred_cipher_shipdate2_temp;
    pred_cipher_discount1[i] = pred_cipher_discount1_temp;
    pred_cipher_discount2[i] = pred_cipher_discount2_temp;
    pred_cipher_quantity[i] = pred_cipher_quantity_temp;
  }

  // Predicate Evaluation
  std::cout << "Start Predicate Evaluation..." << std::endl;
  std::vector<TLWELvl1> pred_shipdate1_cres(rows), pred_shipdate2_cres(rows);
  std::vector<TLWELvl1> pred_discount1_cres(rows), pred_discount2_cres(rows);
  std::vector<TLWELvl1> pred_quantity_cres(rows);
  auto shipdate_bits = data[0].shipdate().bits;
  auto discount_bits = data[0].discount().bits;
  auto quantity_bits = data[0].quantity().bits;

  // ==== find cache filters
  for (int i = 0; i < filters_name.size(); i++) {
    cm.find(filters_name[i], filters[i], metas[i]);
  }
  // ==== end of finding cache filters

  Pointer<BootstrappingData<Lvl02>> pt_bs_data(rows);
  auto &pt_bs_data_lvl1 = pt_bs_data.template safe_cast<BootstrappingData<Lvl01>>();

  std::vector<Pointer<cuTLWE<Lvl2>>> tlwe_data;
  tlwe_data.reserve(4);
  for (size_t i = 0; i < 4; ++i) tlwe_data.emplace_back(rows);

  Pointer<cuTLWE<Lvl2>> *pt_tlwe_data = tlwe_data.data();
  Pointer<cuTLWE<Lvl1>> *pt_tlwe_data_lvl1 = &pt_tlwe_data->template safe_cast<cuTLWE<Lvl1>>();

  filter_time = 0;
  tfhe_correction_time = 0;

  HomFastComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_shipdate1_cres.data(), shipdate_ciphers.data(), pred_cipher_shipdate1.data(),
      shipdate_bits, metas[0].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[0], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_shipdate1_cres.data(), rows, tfhe_correction_time);

  HomFastComp<Lvl02, LT, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_shipdate2_cres.data(), shipdate_ciphers.data(), pred_cipher_shipdate2.data(),
      shipdate_bits, metas[1].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[1], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_shipdate2_cres.data(), rows, tfhe_correction_time);

  HomFastComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_discount1_cres.data(), discount_ciphers.data(), pred_cipher_discount1.data(),
      discount_bits, metas[2].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[2], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_discount1_cres.data(), rows, tfhe_correction_time);

  HomFastComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_discount2_cres.data(), discount_ciphers.data(), pred_cipher_discount2.data(),
      discount_bits, metas[3].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[3], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_discount2_cres.data(), rows, tfhe_correction_time);

  HomFastComp<Lvl02, LT, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_quantity_cres.data(), quantity_ciphers.data(), pred_cipher_quantity.data(),
      quantity_bits, metas[4].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[4], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_quantity_cres.data(), rows, tfhe_correction_time);

  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[0].data(), pred_shipdate1_cres.data(), pred_shipdate2_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[0].data(), pred_cres[0].data(), pred_discount1_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[0].data(), pred_cres[0].data(), pred_discount2_cres.data(),
      rows, filter_time);
  HomAND<ARITHMETIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[0].data(), pred_cres[0].data(), pred_quantity_cres.data(),
      rows, filter_time);

  // check the results
  if (!NOCHECK) {
    std::vector<std::vector<uint32_t>> pred_cres_de(groupby_num,
                                                    std::vector<uint32_t>(rows));
    std::vector<uint32_t> pred_shipdate1_cres_de(rows),
        pred_shipdate2_cres_de(rows);
    std::vector<uint32_t> pred_discount1_cres_de(rows),
        pred_discount2_cres_de(rows);
    std::vector<uint32_t> pred_quantity_cres_de(rows);
    for (size_t i = 0; i < rows; i++) {
      pred_shipdate1_cres_de[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_shipdate1_cres[i], sk.key.lvl1);
      pred_shipdate2_cres_de[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_shipdate2_cres[i], sk.key.lvl1);
      pred_discount1_cres_de[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_discount1_cres[i], sk.key.lvl1);
      pred_discount2_cres_de[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_discount2_cres[i], sk.key.lvl1);
      pred_quantity_cres_de[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_quantity_cres[i], sk.key.lvl1);
      if (pred_shipdate1_cres_de[i] != pred_shipdate1_res[i]) {
        std::cout << "Predicate shipdate1[" << i << "] Error: " << pred_shipdate1_cres_de[i]
                  << " " << pred_shipdate1_res[i] << std::endl;
      }
      if (pred_shipdate2_cres_de[i] != pred_shipdate2_res[i]) {
        std::cout << "Predicate shipdate2[" << i << "] Error: " << pred_shipdate2_cres_de[i]
                  << " " << pred_shipdate2_res[i] << std::endl;
      }
      if (pred_discount1_cres_de[i] != pred_discount1_res[i]) {
        std::cout << "Predicate discount1[" << i << "] Error: " << pred_discount1_cres_de[i]
                  << " " << pred_discount1_res[i] << std::endl;
      }
      if (pred_discount2_cres_de[i] != pred_discount2_res[i]) {
        std::cout << "Predicate discount2[" << i << "] Error: " << pred_discount2_cres_de[i]
                  << " " << pred_discount2_res[i] << std::endl;
      }
      if (pred_quantity_cres_de[i] != pred_quantity_res[i]) {
        std::cout << "Predicate quantity[" << i << "] Error: " << pred_quantity_cres_de[i]
                  << " " << pred_quantity_res[i] << std::endl;
      }
      pred_cres_de[0][i] = TFHEpp::tlweSymInt32Decrypt<Lvl1>(
          pred_cres[0][i], pow(2., 31), sk.key.get<Lvl1>());
    }

    size_t error_time = 0;

    uint32_t rlwe_scale_bits = 29;
    ari_rescale<Lvl10, Lvl01>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_cres[0].data(), pred_cres[0].data(), rlwe_scale_bits, rows);

    for (size_t i = 0; i < rows; i++)
      pred_cres_de[0][i] = TFHEpp::tlweSymInt32Decrypt<Lvl1>(
          pred_cres[0][i], pow(2., 29), sk.key.get<Lvl1>());
    for (size_t i = 0; i < rows; i++)
      error_time += (pred_cres_de[0][i] == pred_res[0][i]) ? 0 : 1;
    std::cout << "Predicate Error: " << error_time << std::endl;
  }

  std::cout << "[PHC] " << filter_time << "ms" << std::endl;
  std::cout << "[TFHE Correction] " << tfhe_correction_time << "ms"
            << std::endl;
  filter_time += tfhe_correction_time;
  std::cout << "[Evaluation] " << filter_time << "ms" << std::endl;
}


void aggregation(std::vector<PhantomCiphertext> &result,
                 std::vector<std::vector<uint32_t>> &pred_res,
                 std::vector<DataRecord> &data,
                 size_t rows,
                 PhantomRLWE &rlwe,
                 double &aggregation_time) {
  std::cout << "Aggregation :" << std::endl;
  size_t groupby_num = result.size();

  // Table for data, ciphertext, and aggregation results
  struct DataPack {
    std::vector<double> &data;
    PhantomCiphertext &cipher;
    std::vector<PhantomCiphertext> &sum;
  };

  // Filter result * data
  // original data
  std::vector<double> count_data(rows);
  // packed ciphertext
  PhantomCiphertext count_cipher;
  // sum result ciphertext
  std::vector<PhantomCiphertext> order_count(groupby_num);
  std::vector<DataPack> table = {{count_data, count_cipher, order_count}};

  auto double_scale = data[0].double_scale;
  for (size_t i = 0; i < rows; i++) {
    count_data[i] =
        data[i].extendedprice().value * data[i].discount().value / double_scale;
  }

  // convert data to ciphertext
  PhantomPlaintext t_plain;
  double qd =
      rlwe.parms.coeff_modulus()[result[0].coeff_modulus_size_ - 1].value();
  for (auto [_data_plaintext, _data_cipher, _sum_cipher] : table) {
    pack_encode(*rlwe.context, _data_plaintext, qd, t_plain, *rlwe.ckks_encoder);
    rlwe.secret_key->encrypt_symmetric(*rlwe.context, t_plain, _data_cipher, false);
  }

  std::cout << "Aggregating price and discount .." << std::endl;
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
      std::chrono::duration_cast<std::chrono::nanoseconds>(end - start)
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
  // Decrypt and check the result
  if (!NOCHECK) {
    std::vector<double> agg_result(rows);
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
  for (size_t i = 0; i < rows; i++) {
    data[i].init();
  }
  query_data.init();

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
    cout << "End-to-End Time: "
         << (filter_time + conversion_time + aggregation_time) / 1000 << " s"
         << endl;

    time.push_back(rows);
    time.push_back(filter_time/1000);
    time.push_back(conversion_time/1000);
    time.push_back(aggregation_time/1000);
    time.push_back((filter_time+conversion_time+aggregation_time)/1000);
    return;
  }

  using T = Lvl1::T;
  CacheManager<Lvl1> cm(&sk, &ek, &rlwe, FAST_COMP);

  std::vector<std::string> filters_name = {"shipdate", "shipdate", "discount1",
                                           "discount2", "quantity"};
  std::vector<std::vector<CacheFilter>> filters(filters_name.size());
  std::vector<CacheMetadata<T>> metas = {
      CacheMetadata<T>(CompLogic::GE, (T)query_data.shipdate1().value),
      CacheMetadata<T>(CompLogic::LT, (T)query_data.shipdate2().value),
      CacheMetadata<T>(CompLogic::GE, (T)query_data.discount1().value),
      CacheMetadata<T>(CompLogic::LE, (T)query_data.discount2().value),
      CacheMetadata<T>(CompLogic::LT, (T)query_data.quantity().value)};

  double filter_time, conversion_time, tfhe_correction_time, ckks_correction_time, aggregation_time;
  std::vector<std::vector<TLWELvl1>> pred_cres;
  std::vector<std::vector<uint32_t>> pred_res;
  std::vector<PhantomCiphertext> results;

  predicate_evaluation_cache(pred_cres, pred_res, data, query_data, sk, ek,
      cm, filters, filters_name, metas, rows, filter_time, tfhe_correction_time);
  rlwe.genLWE2RLWEGaloisKeys();
  conversion(results, pred_cres, pred_res, rlwe, sk, conversion_time, NOCHECK);
  rlwe.genGaloisKeys();
  auto gfilters = std::vector<std::vector<CacheFilter>>();

  filter_correction(results, pred_res, rlwe, filters, gfilters,
                  ckks_correction_time, NOCHECK);

  aggregation(results, pred_res, data, rows, rlwe, aggregation_time);
 cout << "End-to-End Time: "
       << (filter_time + tfhe_correction_time + conversion_time + ckks_correction_time + aggregation_time) / 1000 << " s"
       << endl;
  time.push_back(rows);
  time.push_back((filter_time+tfhe_correction_time+ckks_correction_time)/1000);
  time.push_back(filter_time/1000);
  time.push_back(tfhe_correction_time/1000);
  time.push_back(ckks_correction_time/1000);
  time.push_back(conversion_time/1000);
  time.push_back(aggregation_time/1000);
  time.push_back((filter_time+tfhe_correction_time+ckks_correction_time+conversion_time+aggregation_time)/1000);
}

int main(int argc, char** argv)
{
  argparse::ArgumentParser program("tpch_q6");

  program.add_argument("--nofastcomp")
    .help("disable fastcomp")
    .default_value(false)
    .implicit_value(true);

  program.add_argument("--nocache")
    .help("disable cache")
    .default_value(false)
    .implicit_value(true);

  program.add_argument("--check")
    .help("check result")
    .default_value(false)
    .implicit_value(true);

  program.add_argument("-o", "--output")
    .help("output file")
    .default_value(std::string(""));

  program.add_argument("--rows")
    .help("number of rows")
    .nargs(1,10)
    .scan<'i', int>();

  program.add_argument("-d", "--device")
    .help("device id")
    .default_value(0)
    .scan<'i', int>();

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

  string output_head = CACHE_ENABLED ?
    "rows,fhc,phc,lwe_correct,rlwe_correct,packing,aggregation,end2end" :
    "rows,filter,packing,aggregation,end2end";

  if (output.empty()) {
    cout << "--------------------------------" << endl;
    cout << output_head << endl;
    for (size_t i = 0; i < time.size(); i++) {
      for (size_t j = 0; j < time[i].size(); j++) {
        cout << time[i][j] << ",";
      }
      cout << endl;
    }
  }
  else {
    ofstream ofs(output);
    ofs << output_head << endl;
    for (size_t i = 0; i < time.size(); i++) {
      for (size_t j = 0; j < time[i].size(); j++) {
        ofs << time[i][j] << ",";
      }
      ofs << endl;
    }
  }
}
