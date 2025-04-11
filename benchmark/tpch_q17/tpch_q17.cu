#include <opera.h>
#include <phantom.h>
#include <chrono>
#include <thread>
#include "data_q17.h"

using namespace cuTFHEpp;
using namespace opera;
using namespace std;

bool FAST_COMP = true;
bool CACHE_ENABLED = true;
bool NOCHECK = true;

/***
 * TPC-H Query 17 modified
  select
    sum(l_extendedprice) / 7.0 as avg_yearly
  from
    lineitem,
    part
  where
    p_partkey = l_partkey
    and p_brand = 'Brand#51'
    and p_container = 'WRAP PACK'
    and l_quantity < (
      select
        0.2 * avg(l_quantity)
      from
        lineitem
      where
        l_partkey = p_partkey
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
      quantity_ciphers(rows), avg_quantity_ciphers(rows);
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
    avg_quantity_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.avg_quantity().value, Lvl2::α,
        pow(2., row_data.avg_quantity().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  }

  // Encrypt Predicate values
  std::cout << "Encrypting Predicate Values..." << std::endl;

  // check if the predicate is correct
  auto groupby_num = 1;
  // pred_ship[rows]
  std::vector<uint32_t> pred_brand_res(rows, 0), pred_container_res(rows, 0),
      pred_quantity_res(rows, 0);
  // pred_res[1][rows]
  pred_res.resize(1, std::vector<uint32_t>(rows, 1));
  pred_cres.resize(1, std::vector<TLWELvl1>(rows));

  // pred_part & pred_group
  for (size_t i = 0; i < rows; i++) {
    pred_brand_res[i] = !!(data[i].brand().value == query_data.brand().value);
    pred_container_res[i] =
        !!(data[i].container().value == query_data.container().value);
    pred_quantity_res[i] = !!(data[i].quantity().value < data[i].avg_quantity().value);
  }
  // pred_res
  for (size_t i = 0; i < groupby_num; i++) {
    for (size_t j = 0; j < rows; j++) {
      pred_res[i][j] = pred_brand_res[j] & pred_container_res[j] & pred_quantity_res[j];
    }
  }

  // Encrypt Predicates
  std::vector<TLWELvl2> pred_cipher_brand(rows), pred_cipher_container(rows);
  // encrypt predicate part
  auto pred_cipher_brand_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.brand().value, Lvl2::α,
      pow(2., data[0].brand().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_container_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.container().value, Lvl2::α,
      pow(2., data[0].container().scale_bits<Lvl2>()), sk.key.get<Lvl2>());

  for (size_t i = 0; i < rows; i++) {
    pred_cipher_brand[i] = pred_cipher_brand_temp;
    pred_cipher_container[i] = pred_cipher_container_temp;
  }

  // Predicate Evaluation
  std::cout << "Start Predicate Evaluation..." << std::endl;
  std::vector<TLWELvl1> pred_brand_cres(rows),
      pred_container_cres(rows), pred_quantity_cres(rows);

  auto brand_bits = data[0].brand().bits;
  auto container_bits = data[0].container().bits;
  auto quantity_bits = data[0].quantity().bits;
  auto avg_quantity_bits = data[0].avg_quantity().bits;
  assert(quantity_bits == avg_quantity_bits);

  Pointer<BootstrappingData<Lvl02>> pt_bs_data(rows);
  auto &pt_bs_data_lvl1 = pt_bs_data.template safe_cast<BootstrappingData<Lvl01>>();

  std::vector<Pointer<cuTLWE<Lvl2>>> tlwe_data;
  tlwe_data.reserve(4);
  for (size_t i = 0; i < 4; ++i) tlwe_data.emplace_back(rows);

  Pointer<cuTLWE<Lvl2>> *pt_tlwe_data = tlwe_data.data();
  Pointer<cuTLWE<Lvl1>> *pt_tlwe_data_lvl1 = &pt_tlwe_data->template safe_cast<cuTLWE<Lvl1>>();

  filter_time = 0;

  // p_brand = 'Brand#51'
  HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_brand_cres.data(), brand_ciphers.data(), pred_cipher_brand.data(),
      brand_bits, rows, filter_time);

  // p_container = 'WRAP PACK'
  HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_container_cres.data(), container_ciphers.data(), pred_cipher_container.data(),
      container_bits, rows, filter_time);

  // l_quantity < avg_quantity
  HomComp<Lvl02, LT, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_quantity_cres.data(), quantity_ciphers.data(), avg_quantity_ciphers.data(),
      quantity_bits, rows, filter_time);

  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[0].data(), pred_brand_cres.data(), pred_container_cres.data(),
      rows, filter_time);
  HomAND<ARITHMETIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[0].data(), pred_cres[0].data(), pred_quantity_cres.data(),
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
      quantity_ciphers(rows), avg_quantity_ciphers(rows);
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
    avg_quantity_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.avg_quantity().value, Lvl2::α,
        pow(2., row_data.avg_quantity().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  }

  // Encrypt Predicate values
  std::cout << "Encrypting Predicate Values..." << std::endl;

  // check if the predicate is correct
  auto groupby_num = 1;
  // pred_ship[rows]
  std::vector<uint32_t> pred_brand_res(rows, 0), pred_container_res(rows, 0),
      pred_quantity_res(rows, 0);
  // pred_res[1][rows]
  pred_res.resize(1, std::vector<uint32_t>(rows, 1));
  pred_cres.resize(1, std::vector<TLWELvl1>(rows));

  // pred_part & pred_group
  for (size_t i = 0; i < rows; i++) {
    pred_brand_res[i] = !!(data[i].brand().value == query_data.brand().value);
    pred_container_res[i] =
        !!(data[i].container().value == query_data.container().value);
    pred_quantity_res[i] = !!(data[i].quantity().value < data[i].avg_quantity().value);
  }
  // pred_res
  for (size_t i = 0; i < groupby_num; i++) {
    for (size_t j = 0; j < rows; j++) {
      pred_res[i][j] = pred_brand_res[j] & pred_container_res[j] & pred_quantity_res[j];
    }
  }

  // ==== generate cache filters
  std::vector<Lvl1::T> data_brand, data_container;
  std::cout << "Cache Filter Generation..." << std::endl;
  std::transform(data.begin(), data.end(), std::back_inserter(data_brand),
                 [](DataRecord &d) { return d.brand().value; });
  std::transform(data.begin(), data.end(), std::back_inserter(data_container),
                 [](DataRecord &d) { return d.container().value; });
  
  // p_brand = 'Brand#51'
  cm.generate(filters_name[0], data_brand, metas[0]);
  // p_container = 'WRAP PACK'
  cm.generate(filters_name[1], data_container, metas[1]);
  // l_quantity < avg_quantity
  cm.generate(filters_name[2], pred_quantity_res, metas[2]);
  // ==== end of cache filter generation

  // Encrypt Predicates
  std::vector<TLWELvl2> pred_cipher_brand(rows), pred_cipher_container(rows);
  // encrypt predicate part
  auto pred_cipher_brand_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.brand().value, Lvl2::α,
      pow(2., data[0].brand().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_container_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.container().value, Lvl2::α,
      pow(2., data[0].container().scale_bits<Lvl2>()), sk.key.get<Lvl2>());

  for (size_t i = 0; i < rows; i++) {
    pred_cipher_brand[i] = pred_cipher_brand_temp;
    pred_cipher_container[i] = pred_cipher_container_temp;
  }

  // Predicate Evaluation
  std::cout << "Start Predicate Evaluation..." << std::endl;
  std::vector<TLWELvl1> pred_brand_cres(rows),
      pred_container_cres(rows), pred_quantity_cres(rows);

  auto brand_bits = data[0].brand().bits;
  auto container_bits = data[0].container().bits;
  auto quantity_bits = data[0].quantity().bits;
  auto avg_quantity_bits = data[0].avg_quantity().bits;
  assert(quantity_bits == avg_quantity_bits);

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

  // p_brand = 'Brand#51'
  HomFastComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_brand_cres.data(), brand_ciphers.data(), pred_cipher_brand.data(),
      brand_bits, metas[0].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[0], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_brand_cres.data(), rows, tfhe_correction_time);

  // p_container = 'WRAP PACK'
  HomFastComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_container_cres.data(), container_ciphers.data(), pred_cipher_container.data(),
      container_bits, metas[1].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[1], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_container_cres.data(), rows, tfhe_correction_time);

  // l_quantity < avg_quantity
  HomFastComp<Lvl02, LT, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_quantity_cres.data(), quantity_ciphers.data(), avg_quantity_ciphers.data(),
      quantity_bits, metas[2].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[2], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_quantity_cres.data(), rows, tfhe_correction_time);

  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[0].data(), pred_brand_cres.data(), pred_container_cres.data(),
      rows, filter_time);
  HomAND<ARITHMETIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_cres[0].data(), pred_cres[0].data(), pred_quantity_cres.data(),
      rows, filter_time);

  // check the results
  if (!NOCHECK) {
    std::vector<uint32_t> brand_res_de(rows), container_res_de(rows),
        quantity_res_de(rows);
    for (size_t i = 0; i < rows; i++) {
      brand_res_de[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_brand_cres[i], sk.key.lvl1);
      container_res_de[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_container_cres[i], sk.key.lvl1);
      quantity_res_de[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_quantity_cres[i], sk.key.lvl1);
      if (brand_res_de[i] != pred_brand_res[i]) {
        std::cout << "Predicate brand Error: " << brand_res_de[i] << " "
                  << pred_brand_res[i] << std::endl;
      }
      if (container_res_de[i] != pred_container_res[i]) {
        std::cout << "Predicate container Error: " << container_res_de[i] << " "
                  << pred_container_res[i] << std::endl;
      }
      if (quantity_res_de[i] != pred_quantity_res[i]) {
        std::cout << "Predicate quantity Error: " << quantity_res_de[i] << " "
                  << pred_quantity_res[i] << std::endl;
      }
    }

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
  std::vector<double> extendedprice_data(rows);
  // packed ciphertext
  PhantomCiphertext extendedprice_cipher;
  // sum result ciphertext
  std::vector<PhantomCiphertext> sum_extendedprice(groupby_num);
  std::vector<DataPack> table = {
    {extendedprice_data, extendedprice_cipher, sum_extendedprice}};

  for (size_t i = 0; i < rows; i++) {
    extendedprice_data[i] = data[i].extendedprice().value;
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
    record_e2e_time(time, rows, filter_time, conversion_time, aggregation_time);
    return;
  }

  using T = Lvl1::T;
  CacheManager<Lvl1> cm(&sk, &ek, &rlwe, FAST_COMP);

  std::vector<std::string> filters_name = {
    "brand", "container", "quantity"
  };
  std::vector<std::vector<CacheFilter>> filters(filters_name.size());
  std::vector<CacheMetadata<T>> metas = {
      CacheMetadata<T>(CompLogic::EQ, (T)query_data.brand().value),
      CacheMetadata<T>(CompLogic::EQ, (T)query_data.container().value),
      CacheMetadata<T>(CompLogic::NE, (T)0),
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
  argparse::ArgumentParser program("tpch_q17");

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
