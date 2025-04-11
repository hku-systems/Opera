#include <opera.h>
#include <phantom.h>
#include <chrono>
#include <thread>
#include "data_q15.h"

using namespace cuTFHEpp;
using namespace opera;
using namespace std;

bool FAST_COMP = true;
bool CACHE_ENABLED = true;
bool NOCHECK = true;

/***
 * TPC-H Query 15 modified
  with revenue0(SUPPLIER_NO, TOTAL_REVENUE)  as
  (
  select
    l_suppkey,
    sum(l_extendedprice * (1 - l_discount))
  from
    lineitem
  where
    l_shipdate >= date '1995-02-01'
    and l_shipdate < date '1995-02-01' + interval '3' month
  group by
    l_suppkey
  )

select
  s_suppkey,
  s_name,
  s_address,
  s_phone,
  total_revenue
from
  supplier,
  revenue0
where
  s_suppkey = supplier_no
  and total_revenue = (
    select
      max(total_revenue)
    from
      revenue0
  )

    consider data encode by [yyyymmdd], 26 bits,
    group by $m$ types of l_suppkey, and in plaintext
    (lineitem and supplier can join by l_suppkey = s_suppkey)
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
  std::vector<TLWELvl2> shipdate_ciphers(rows);
  for (size_t i = 0; i < rows; i++) {
    auto row_data = data[i];
    shipdate_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.shipdate().value, Lvl2::α,
        pow(2., row_data.shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  }

  // Encrypt Predicate values
  std::cout << "Encrypting Predicate Values..." << std::endl;

  // check if the predicate is correct
  auto supplier_num = query_data.total_revenue().size();
  // pred_ship_res
  std::vector<uint32_t> pred_ship_res(rows, 0);
  // pred_group[rows][supplier_num]
  std::vector<std::vector<uint32_t>> pred_group_res(
      supplier_num, std::vector<uint32_t>(rows, 0));
  // pred_res[supplier_num][rows]
  pred_res.resize(supplier_num, std::vector<uint32_t>(rows, 0));
  pred_cres.resize(supplier_num, std::vector<TLWELvl1>(rows));

  // get each max value of total_revenue
  std::vector<uint32_t> total_revenue(supplier_num, 0);

  // pred_part & pred_group
  for (size_t i = 0; i < rows; i++) {
    auto shipdate1 = query_data.shipdate1();
    auto shipdate2 = query_data.shipdate2();
    pred_ship_res[i] = !!(data[i].shipdate().value >= shipdate1.value &&
                          data[i].shipdate().value < shipdate2.value);

    // suppkey is in plaintext
    for (size_t j = 0; j < supplier_num; j++) {
      pred_group_res[j][i] = (j == data[i].suppkey().value);
    }
  }
  // pred_res
  for (size_t i = 0; i < supplier_num; i++) {
    for (size_t j = 0; j < rows; j++) {
      pred_res[i][j] = pred_group_res[i][j] & pred_ship_res[j];
    }
  }

  // Encrypt Predicates
  std::vector<TLWELvl2> pred_cipher_ship1(rows), pred_cipher_ship2(rows);
  std::vector<std::vector<TLWELvl1>> pred_cipher_revenue(
      supplier_num, std::vector<TLWELvl1>(rows));
  // encrypt predicate part
  auto pred_cipher_ship1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.shipdate1().value, Lvl2::α,
      pow(2., data[0].shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_ship2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.shipdate2().value, Lvl2::α,
      pow(2., data[0].shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  for (size_t i = 0; i < rows; i++) {
    pred_cipher_ship1[i] = pred_cipher_ship1_temp;
    pred_cipher_ship2[i] = pred_cipher_ship2_temp;
  }
  // encrypt group by part
  double revenue_scale = pow(2., 31);
  for (size_t i = 0; i < supplier_num; i++) {
    for (size_t j = 0; j < rows; j++) {
      pred_cipher_revenue[i][j] = TFHEpp::tlweSymEncrypt<Lvl1>(
          pred_group_res[i][j] ? Lvl1::μ : -Lvl1::μ, Lvl1::α,
          sk.key.get<Lvl1>());
    }
  }

  // Predicate Evaluation
  std::cout << "Start Predicate Evaluation..." << std::endl;
  std::vector<TLWELvl1> pred_ship_cres1(rows), pred_ship_cres2(rows),
      pred_ship_cres(rows);
  auto ship_bits = data[0].shipdate().bits;

  Pointer<BootstrappingData<Lvl02>> pt_bs_data(rows);
  auto &pt_bs_data_lvl1 = pt_bs_data.template safe_cast<BootstrappingData<Lvl01>>();

  std::vector<Pointer<cuTLWE<Lvl2>>> tlwe_data;
  tlwe_data.reserve(4);
  for (size_t i = 0; i < 4; ++i) tlwe_data.emplace_back(rows);

  Pointer<cuTLWE<Lvl2>> *pt_tlwe_data = tlwe_data.data();
  Pointer<cuTLWE<Lvl1>> *pt_tlwe_data_lvl1 = &pt_tlwe_data->template safe_cast<cuTLWE<Lvl1>>();

  filter_time = 0;

  // l_shipdate >= date '1995-02-01'
  HomComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_ship_cres1.data(), shipdate_ciphers.data(), pred_cipher_ship1.data(),
      ship_bits, rows, filter_time);

  // l_shipdate < date '1995-02-01' + interval '3' month
  HomComp<Lvl02, LT, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_ship_cres2.data(), shipdate_ciphers.data(), pred_cipher_ship2.data(),
      ship_bits, rows, filter_time);

  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_ship_cres.data(), pred_ship_cres1.data(), pred_ship_cres2.data(),
      rows, filter_time);

  // group by l_suppkey
  for (size_t j = 0; j < supplier_num; j++) {
    HomAND<ARITHMETIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[j].data(), pred_ship_cres.data(), pred_cipher_revenue[j].data(),
      rows, filter_time);
  }

  // check the results
  if (!NOCHECK) {
    std::vector<std::vector<uint32_t>> pred_cres_de(supplier_num,
                                                    std::vector<uint32_t>(rows));
    size_t error_time = 0;

    uint32_t rlwe_scale_bits = 29;
    for (size_t j = 0; j < supplier_num; j++)
      ari_rescale<Lvl10, Lvl01>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
          pred_cres[j].data(), pred_cres[j].data(), rlwe_scale_bits, rows);

    for (size_t i = 0; i < rows; i++)
      for (size_t j = 0; j < supplier_num; j++) {
        pred_cres_de[j][i] = TFHEpp::tlweSymInt32Decrypt<Lvl1>(
            pred_cres[j][i], pow(2., 29), sk.key.get<Lvl1>());
      }
    for (size_t i = 0; i < rows; i++)
      for (size_t j = 0; j < supplier_num; j++)
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
  std::vector<TLWELvl2> shipdate_ciphers(rows);
  for (size_t i = 0; i < rows; i++) {
    auto row_data = data[i];
    shipdate_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.shipdate().value, Lvl2::α,
        pow(2., row_data.shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  }

  // Encrypt Predicate values
  std::cout << "Encrypting Predicate Values..." << std::endl;

  // check if the predicate is correct
  auto supplier_num = query_data.total_revenue().size();
  // pred_ship_res
  std::vector<uint32_t> pred_ship_res1(rows, 0), pred_ship_res2(rows, 0);
  // pred_group[rows][supplier_num]
  std::vector<std::vector<uint32_t>> pred_group_res(
      supplier_num, std::vector<uint32_t>(rows, 0));
  // pred_res[supplier_num][rows]
  pred_res.resize(supplier_num, std::vector<uint32_t>(rows, 0));
  pred_cres.resize(supplier_num, std::vector<TLWELvl1>(rows));

  // get each max value of total_revenue
  std::vector<uint32_t> total_revenue(supplier_num, 0);

  // pred_part & pred_group
  for (size_t i = 0; i < rows; i++) {
    auto shipdate1 = query_data.shipdate1();
    auto shipdate2 = query_data.shipdate2();
    pred_ship_res1[i] = !!(data[i].shipdate().value >= shipdate1.value);
    pred_ship_res2[i] = !!(data[i].shipdate().value < shipdate2.value);

    // suppkey is in plaintext
    for (size_t j = 0; j < supplier_num; j++) {
      pred_group_res[j][i] = (j == data[i].suppkey().value);
    }
  }
  // pred_res
  for (size_t i = 0; i < supplier_num; i++) {
    for (size_t j = 0; j < rows; j++) {
      pred_res[i][j] = pred_group_res[i][j] && pred_ship_res1[j] && pred_ship_res2[j];
    }
  }

  // ==== generate cache filters
  std::vector<Lvl1::T> data_shipdate;
  std::cout << "Cache Filter Generation..." << std::endl;
  std::transform(data.begin(), data.end(), std::back_inserter(data_shipdate),
                 [](DataRecord &d) { return d.shipdate().value; });
  
  // l_shipdate >= date '1995-02-01'
  cm.generate(filters_name[0], data_shipdate, metas[0]);
  // l_shipdate < date '1995-02-01' + interval '3' month
  cm.generate(filters_name[1], data_shipdate, metas[1]);
  // ==== end of cache filter generation

  // Encrypt Predicates
  std::vector<TLWELvl2> pred_cipher_ship1(rows), pred_cipher_ship2(rows);
  std::vector<std::vector<TLWELvl1>> pred_cipher_revenue(
      supplier_num, std::vector<TLWELvl1>(rows));
  // encrypt predicate part
  auto pred_cipher_ship1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.shipdate1().value, Lvl2::α,
      pow(2., data[0].shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_ship2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.shipdate2().value, Lvl2::α,
      pow(2., data[0].shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  for (size_t i = 0; i < rows; i++) {
    pred_cipher_ship1[i] = pred_cipher_ship1_temp;
    pred_cipher_ship2[i] = pred_cipher_ship2_temp;
  }
  // encrypt group by part
  double revenue_scale = pow(2., 31);
  for (size_t i = 0; i < supplier_num; i++) {
    for (size_t j = 0; j < rows; j++) {
      pred_cipher_revenue[i][j] = TFHEpp::tlweSymEncrypt<Lvl1>(
          pred_group_res[i][j] ? Lvl1::μ : -Lvl1::μ, Lvl1::α,
          sk.key.get<Lvl1>());
    }
  }

  // Predicate Evaluation
  std::cout << "Start Predicate Evaluation..." << std::endl;
  std::vector<TLWELvl1> pred_ship_cres1(rows), pred_ship_cres2(rows),
      pred_ship_cres(rows);
  auto ship_bits = data[0].shipdate().bits;

  // ==== find cache filters
  // predicates
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

  // l_shipdate >= date '1995-02-01'
  HomFastComp<Lvl02, GE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_ship_cres1.data(), shipdate_ciphers.data(), pred_cipher_ship1.data(),
      ship_bits, metas[0].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[0], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_ship_cres1.data(), rows, tfhe_correction_time);

  // l_shipdate < date '1995-02-01' + interval '3' month
  HomFastComp<Lvl02, LT, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_ship_cres2.data(), shipdate_ciphers.data(), pred_cipher_ship2.data(),
      ship_bits, metas[1].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[1], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_ship_cres2.data(), rows, tfhe_correction_time);

  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_ship_cres.data(), pred_ship_cres1.data(), pred_ship_cres2.data(),
      rows, filter_time);

  // group by l_suppkey
  for (size_t j = 0; j < supplier_num; j++) {
    HomAND<ARITHMETIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[j].data(), pred_ship_cres.data(), pred_cipher_revenue[j].data(),
      rows, filter_time);
  }

  // check the results
  if (!NOCHECK) {
    std::vector<uint32_t> pred_ship_dres1(rows), pred_ship_dres2(rows);
    for (size_t i = 0; i < rows; i++) {
      pred_ship_dres1[i] = TFHEpp::tlweSymDecrypt<Lvl1>(pred_ship_cres1[i], sk.key.lvl1);
      pred_ship_dres2[i] = TFHEpp::tlweSymDecrypt<Lvl1>(pred_ship_cres2[i], sk.key.lvl1);
      if (pred_ship_dres1[i] != pred_ship_res1[i]) {
        std::cout << "Predicate shipdate1 Error: " << pred_ship_dres1[i] << " "
                  << pred_ship_res1[i] << std::endl;
      }
      if (pred_ship_dres2[i] != pred_ship_res2[i]) {
        std::cout << "Predicate shipdate2 Error: " << pred_ship_dres2[i] << " "
                  << pred_ship_res2[i] << std::endl;
      }
    }

    std::vector<std::vector<uint32_t>> pred_cres_de(supplier_num,
                                                    std::vector<uint32_t>(rows));
    size_t error_time = 0;

    uint32_t rlwe_scale_bits = 29;
    for (size_t j = 0; j < supplier_num; j++)
      ari_rescale<Lvl10, Lvl01>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
          pred_cres[j].data(), pred_cres[j].data(), rlwe_scale_bits, rows);

    for (size_t i = 0; i < rows; i++)
      for (size_t j = 0; j < supplier_num; j++) {
        pred_cres_de[j][i] = TFHEpp::tlweSymInt32Decrypt<Lvl1>(
            pred_cres[j][i], pow(2., 29), sk.key.get<Lvl1>());
      }
    for (size_t i = 0; i < rows; i++)
      for (size_t j = 0; j < supplier_num; j++)
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
  int supplier_size = std::max((size_t)1, rows >> 8); // row / 256
  for (size_t i = 0; i < rows; i++) {
    data[i].init(supplier_size);
  }
  query_data.init(supplier_size);

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
    "shipdate1", "shipdate2"
  };
  std::vector<std::vector<CacheFilter>> filters(filters_name.size());
  std::vector<CacheMetadata<T>> metas = {
    CacheMetadata<T>(CompLogic::GE, (T)query_data.shipdate1().value),
    CacheMetadata<T>(CompLogic::LT, (T)query_data.shipdate2().value),
  };

  size_t group_size = 0;
  std::vector<std::string> gfilters_name;
  std::vector<std::vector<CacheFilter>> gfilters(0);
  std::vector<CacheMetadata<T>> gmetas;
  for (size_t i = 0; i < group_size; ++i) {
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
  argparse::ArgumentParser program("tpch_q15");

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
