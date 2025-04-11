#include <opera.h>
#include <phantom.h>
#include <chrono>
#include <thread>
#include "data_q12.h"

using namespace cuTFHEpp;
using namespace opera;
using namespace std;

bool FAST_COMP = true;
bool CACHE_ENABLED = true;
bool NOCHECK = true;

/***
 * TPC-H Query 12 modified
  select
    l_shipmode,
    sum(case
      when o_orderpriority = '1-URGENT'
        or o_orderpriority = '2-HIGH'
        then 1
      else 0
    end) as high_line_count,
    sum(case
      when o_orderpriority <> '1-URGENT'
        and o_orderpriority <> '2-HIGH'
        then 1
      else 0
    end) as low_line_count
  from
    orders,
    lineitem
  where
    o_orderkey = l_orderkey
    and l_shipmode in ('FOB', 'AIR')
    and l_commitdate < l_receiptdate
    and l_shipdate < l_commitdate
    and l_receiptdate >= date '1997-01-01'
    and l_receiptdate < date '1997-01-01' + interval '1' year
  group by
    l_shipmode

    consider data encode by [yyyymmdd], 26 bits,
    group by $m$ types of l_shipmode
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
  std::vector<TLWELvl1> shipmode_ciphers(rows);
  std::vector<TLWELvl2> orderpriority_ciphers(rows), commitdate_ciphers(rows),
      shipdate_ciphers(rows), receiptdate_ciphers(rows);
  for (size_t i = 0; i < rows; i++) {
    auto row_data = data[i];
    shipmode_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl1>(
        row_data.shipmode().value, Lvl1::α,
        pow(2., row_data.shipmode().scale_bits<Lvl1>()), sk.key.get<Lvl1>());
    orderpriority_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.orderpriority().value, Lvl2::α,
        pow(2., row_data.orderpriority().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    commitdate_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.commitdate().value, Lvl2::α,
        pow(2., row_data.commitdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    shipdate_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.shipdate().value, Lvl2::α,
        pow(2., row_data.shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    receiptdate_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.receiptdate().value, Lvl2::α,
        pow(2., row_data.receiptdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  }

  // Encrypt Predicate values
  std::cout << "Encrypting Predicate Values..." << std::endl;

  // pred_receiptdate1[rows], pred_receiptdate2[rows]
  std::vector<uint32_t> pred_receiptdate1(rows, 0);
  std::vector<uint32_t> pred_receiptdate2(rows, 0);
  // pred_commitdate[rows], pred_shipdate[rows]
  std::vector<uint32_t> pred_commitdate(rows, 0);
  std::vector<uint32_t> pred_shipdate(rows, 0);
  // pred_orderpriority
  std::vector<uint32_t> pred_orderpriority(rows, 0);
  // pred_result
  std::vector<uint32_t> pred_pred_res(rows, 0);
  // pred_group[groupby_num][rows]
  size_t groupby_num = query_data.shipmode().size();
  std::vector<std::vector<uint32_t>> pred_group_res(
      groupby_num, std::vector<uint32_t>(rows, 0));
  // pred_res[groupby_num = shipmode.size()][rows]
  pred_res.resize(groupby_num, std::vector<uint32_t>(rows, 1));
  pred_cres.resize(groupby_num, std::vector<TLWELvl1>(rows));

  // pred_part
  auto receiptdate1_record = query_data.receiptdate1();
  auto receiptdate2_record = query_data.receiptdate2();
  for (size_t i = 0; i < rows; i++) {
    pred_receiptdate1[i] = !!(data[i].receiptdate().value >= receiptdate1_record.value);
    pred_receiptdate2[i] = !!(data[i].receiptdate().value < receiptdate2_record.value);
    pred_commitdate[i] = !!((data[i].commitdate().value < data[i].receiptdate().value));
    pred_shipdate[i] = !!((data[i].shipdate().value < data[i].commitdate().value));
    pred_orderpriority[i] = !!(data[i].orderpriority().value == 1 || data[i].orderpriority().value == 2);
    pred_pred_res[i] = !!(pred_receiptdate1[i] & pred_receiptdate2[i] & pred_commitdate[i] & pred_shipdate[i] & pred_orderpriority[i]);
    for (size_t j = 0; j < groupby_num; j++) {
      pred_group_res[j][i] = !!(data[i].shipmode().value ==
                                query_data.shipmode()[j].value);
    }
  }
  // pred_res
  for (size_t i = 0; i < groupby_num; i++) {
    for (size_t j = 0; j < rows; j++) {
      pred_res[i][j] = pred_group_res[i][j] & pred_pred_res[j];
    }
  }

  // Encrypt Predicates
  std::vector<TLWELvl2> pred_cipher_receiptdate1(rows), pred_cipher_receiptdate2(rows);
  std::vector<TLWELvl2> pred_cipher_orderpriority1(rows), pred_cipher_orderpriority2(rows);
  // pred_cipher_group
  std::vector<std::vector<TLWELvl1>> pred_cipher_shipmode(groupby_num);
  // encrypt predicate part
  auto pred_cipher_receiptdate1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        query_data.receiptdate1().value, Lvl2::α,
        pow(2., data[0].receiptdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_receiptdate2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        query_data.receiptdate2().value, Lvl2::α,
        pow(2., data[0].receiptdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_orderpriority1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        1, Lvl2::α, pow(2., data[0].orderpriority().scale_bits<Lvl2>()),
        sk.key.get<Lvl2>());
  auto pred_cipher_orderpriority2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        2, Lvl2::α, pow(2., data[0].orderpriority().scale_bits<Lvl2>()),
        sk.key.get<Lvl2>());
  for (size_t i = 0; i < rows; i++) {
    pred_cipher_receiptdate1[i] = pred_cipher_receiptdate1_temp;
    pred_cipher_receiptdate2[i] = pred_cipher_receiptdate2_temp;
    pred_cipher_orderpriority1[i] = pred_cipher_orderpriority1_temp;
    pred_cipher_orderpriority2[i] = pred_cipher_orderpriority2_temp;
  }

  // encrypt group by part
  double shipmode_scale = pow(2., data[0].shipmode().scale_bits<Lvl1>());
  auto shipmode_group = query_data.shipmode();
  for (size_t i = 0; i < groupby_num; i++) {
    auto pred_cipher_shipmode_temp =
        TFHEpp::tlweSymInt32Encrypt<Lvl1>(shipmode_group[i].value, Lvl1::α,
                                          shipmode_scale, sk.key.get<Lvl1>());
    pred_cipher_shipmode[i].resize(rows);
    for (size_t j = 0; j < rows; j++) {
      pred_cipher_shipmode[i][j] = pred_cipher_shipmode_temp;
    }
  }

  // Predicate Evaluation
  std::cout << "Start Predicate Evaluation..." << std::endl;
  std::vector<TLWELvl1> pred_commitdate_cres(rows), pred_shipdate_cres(rows),
      pred_receiptdate1_cres(rows), pred_receiptdate2_cres(rows);
  std::vector<TLWELvl1> pred_pred_cres(rows);
  auto date_bits = data[0].commitdate().bits;
  // for orderpriority
  std::vector<TLWELvl1> pred_orderpriority1_cres(rows),
      pred_orderpriority2_cres(rows);
  std::vector<TLWELvl1> pred_orderpriority_cres(rows);
  auto orderpriority_bits = data[0].orderpriority().bits;
  // for shipmode
  std::vector<std::vector<TLWELvl1>> pred_group_cres(
      groupby_num, std::vector<TLWELvl1>(rows));
  auto shipmode_bits = data[0].shipmode().bits;

  Pointer<BootstrappingData<Lvl02>> pt_bs_data(rows);
  auto &pt_bs_data_lvl1 = pt_bs_data.template safe_cast<BootstrappingData<Lvl01>>();

  std::vector<Pointer<cuTLWE<Lvl2>>> tlwe_data;
  tlwe_data.reserve(4);
  for (size_t i = 0; i < 4; ++i) tlwe_data.emplace_back(rows);

  Pointer<cuTLWE<Lvl2>> *pt_tlwe_data = tlwe_data.data();
  Pointer<cuTLWE<Lvl1>> *pt_tlwe_data_lvl1 = &pt_tlwe_data->template safe_cast<cuTLWE<Lvl1>>();

  filter_time = 0;

  // l_commitdate < l_receiptdate
  HomComp<Lvl02, LT, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_commitdate_cres.data(), commitdate_ciphers.data(), receiptdate_ciphers.data(),
      date_bits, rows, filter_time);

  // l_shipdate < l_commitdate
  HomComp<Lvl02, LT, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_shipdate_cres.data(), shipdate_ciphers.data(), commitdate_ciphers.data(),
      date_bits, rows, filter_time);

  // l_receiptdate >= date
  HomComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_receiptdate1_cres.data(), receiptdate_ciphers.data(), pred_cipher_receiptdate1.data(),
      date_bits, rows, filter_time);

  // l_receiptdate < date
  HomComp<Lvl02, LT, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_receiptdate2_cres.data(), receiptdate_ciphers.data(), pred_cipher_receiptdate2.data(),
      date_bits, rows, filter_time);

  // AND all predicates
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_pred_cres.data(), pred_commitdate_cres.data(), pred_shipdate_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_pred_cres.data(), pred_pred_cres.data(), pred_receiptdate1_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_pred_cres.data(), pred_pred_cres.data(), pred_receiptdate2_cres.data(),
      rows, filter_time);

  // orderpriority = '1-URGENT' or orderpriority = '2-HIGH'
  HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_orderpriority1_cres.data(), orderpriority_ciphers.data(), pred_cipher_orderpriority1.data(),
      orderpriority_bits, rows, filter_time);
  HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_orderpriority2_cres.data(), orderpriority_ciphers.data(), pred_cipher_orderpriority2.data(),
      orderpriority_bits, rows, filter_time);
  HomOR<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_orderpriority_cres.data(), pred_orderpriority1_cres.data(), pred_orderpriority2_cres.data(),
      rows, filter_time);
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_pred_cres.data(), pred_pred_cres.data(), pred_orderpriority_cres.data(),
      rows, filter_time);

  // shipmode in ('FOB', 'AIR')
  for (size_t i = 0; i < groupby_num; i++) {
    HomComp<Lvl01, EQ, LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_group_cres[i].data(), shipmode_ciphers.data(), pred_cipher_shipmode[i].data(),
        shipmode_bits, rows, filter_time);
    HomAND<ARITHMETIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_cres[i].data(), pred_pred_cres.data(), pred_group_cres[i].data(),
        rows, filter_time);
  }

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
  std::vector<TLWELvl1> shipmode_ciphers(rows);
  std::vector<TLWELvl2> orderpriority_ciphers(rows), commitdate_ciphers(rows),
      shipdate_ciphers(rows), receiptdate_ciphers(rows);
  for (size_t i = 0; i < rows; i++) {
    auto row_data = data[i];
    shipmode_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl1>(
        row_data.shipmode().value, Lvl1::α,
        pow(2., row_data.shipmode().scale_bits<Lvl1>()), sk.key.get<Lvl1>());
    orderpriority_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.orderpriority().value, Lvl2::α,
        pow(2., row_data.orderpriority().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    commitdate_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.commitdate().value, Lvl2::α,
        pow(2., row_data.commitdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    shipdate_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.shipdate().value, Lvl2::α,
        pow(2., row_data.shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
    receiptdate_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.receiptdate().value, Lvl2::α,
        pow(2., row_data.receiptdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  }

  // Encrypt Predicate values
  std::cout << "Encrypting Predicate Values..." << std::endl;

  // pred_receiptdate1[rows], pred_receiptdate2[rows]
  std::vector<uint32_t> pred_receiptdate1(rows, 0);
  std::vector<uint32_t> pred_receiptdate2(rows, 0);
  // pred_commitdate[rows], pred_shipdate[rows]
  std::vector<uint32_t> pred_commitdate(rows, 0);
  std::vector<uint32_t> pred_shipdate(rows, 0);
  // pred_orderpriority
  std::vector<uint32_t> pred_orderpriority(rows, 0);
  // pred_result
  std::vector<uint32_t> pred_pred_res(rows, 0);
  // pred_group[groupby_num][rows]
  size_t groupby_num = query_data.shipmode().size();
  std::vector<std::vector<uint32_t>> pred_group_res(
      groupby_num, std::vector<uint32_t>(rows, 0));
  // pred_res[groupby_num = shipmode.size()][rows]
  pred_res.resize(groupby_num, std::vector<uint32_t>(rows, 1));
  pred_cres.resize(groupby_num, std::vector<TLWELvl1>(rows));

  // pred_part
  auto receiptdate_low = query_data.receiptdate1().value;
  auto receiptdate_high = query_data.receiptdate2().value;
  for (size_t i = 0; i < rows; i++) {
    pred_receiptdate1[i] = !!(data[i].receiptdate().value >= receiptdate_low);
    pred_receiptdate2[i] = !!(data[i].receiptdate().value < receiptdate_high);
    pred_commitdate[i] = !!((data[i].commitdate().value < data[i].receiptdate().value));
    pred_shipdate[i] = !!((data[i].shipdate().value < data[i].commitdate().value));
    pred_orderpriority[i] = !!(data[i].orderpriority().value == 1 || data[i].orderpriority().value == 2);
    pred_pred_res[i] = !!(pred_receiptdate1[i] & pred_receiptdate2[i] & pred_commitdate[i] & pred_shipdate[i] & pred_orderpriority[i]);
    for (size_t j = 0; j < groupby_num; j++) {
      pred_group_res[j][i] = !!(data[i].shipmode().value ==
                                query_data.shipmode()[j].value);
    }
  }
  // pred_res
  for (size_t i = 0; i < groupby_num; i++) {
    for (size_t j = 0; j < rows; j++) {
      pred_res[i][j] = pred_group_res[i][j] & pred_pred_res[j];
    }
  }

  // ==== generate cache filters
  std::vector<Lvl1::T> data_receiptdate;
  std::cout << "Cache Filter Generation..." << std::endl;
  std::transform(data.begin(), data.end(), std::back_inserter(data_receiptdate),
                 [](DataRecord &d) { return d.receiptdate().value; });

  // l_receiptdate >= date (receiptdate1)
  cm.generate(filters_name[0], data_receiptdate, metas[0]);
  // l_receiptdate < date (receiptdate2)
  cm.generate(filters_name[1], data_receiptdate, metas[1]);
  // l_commitdate < l_receiptdate (commitdate)
  cm.generate(filters_name[2], pred_commitdate, metas[2]);
  // l_shipdate < l_commitdate (shipdate)
  cm.generate(filters_name[3], pred_shipdate, metas[3]);
  // orderpriority = '1-URGENT' or orderpriority = '2-HIGH' (orderpriority)
  cm.generate(filters_name[4], pred_orderpriority, metas[4]);

  // shipmode in ('FOB', 'AIR') (shipmode)
  size_t i = 0;
  std::vector<Lvl1::T> data_shipmode;
  std::transform(data.begin(), data.end(), std::back_inserter(data_shipmode),
                 [](DataRecord &item) { return item.shipmode().value; });
  for (size_t j = 0; j < gfilters[0].size(); ++i, ++j)
    cm.generate(gfilters_name[i], data_shipmode, gmetas[i]);
  // ==== end of cache filter generation

  // Encrypt Predicates
  std::vector<TLWELvl2> pred_cipher_receiptdate1(rows), pred_cipher_receiptdate2(rows);
  std::vector<TLWELvl2> pred_cipher_orderpriority1(rows), pred_cipher_orderpriority2(rows);
  // pred_cipher_group
  std::vector<std::vector<TLWELvl1>> pred_cipher_shipmode(groupby_num);
  // encrypt predicate part
  auto pred_cipher_receiptdate1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        query_data.receiptdate1().value, Lvl2::α,
        pow(2., data[0].receiptdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_receiptdate2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        query_data.receiptdate2().value, Lvl2::α,
        pow(2., data[0].receiptdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  auto pred_cipher_orderpriority1_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        1, Lvl2::α, pow(2., data[0].orderpriority().scale_bits<Lvl2>()),
        sk.key.get<Lvl2>());
  auto pred_cipher_orderpriority2_temp = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        2, Lvl2::α, pow(2., data[0].orderpriority().scale_bits<Lvl2>()),
        sk.key.get<Lvl2>());
  for (size_t i = 0; i < rows; i++) {
    pred_cipher_receiptdate1[i] = pred_cipher_receiptdate1_temp;
    pred_cipher_receiptdate2[i] = pred_cipher_receiptdate2_temp;
    pred_cipher_orderpriority1[i] = pred_cipher_orderpriority1_temp;
    pred_cipher_orderpriority2[i] = pred_cipher_orderpriority2_temp;
  }

  // encrypt group by part
  double shipmode_scale = pow(2., data[0].shipmode().scale_bits<Lvl1>());
  auto shipmode_group = query_data.shipmode();
  for (size_t i = 0; i < groupby_num; i++) {
    auto pred_cipher_shipmode_temp =
        TFHEpp::tlweSymInt32Encrypt<Lvl1>(shipmode_group[i].value, Lvl1::α,
                                          shipmode_scale, sk.key.get<Lvl1>());
    pred_cipher_shipmode[i].resize(rows);
    for (size_t j = 0; j < rows; j++) {
      pred_cipher_shipmode[i][j] = pred_cipher_shipmode_temp;
    }
  }

  // Predicate Evaluation
  std::cout << "Start Predicate Evaluation..." << std::endl;
  std::vector<TLWELvl1> pred_commitdate_cres(rows), pred_shipdate_cres(rows),
      pred_receiptdate1_cres(rows), pred_receiptdate2_cres(rows);
  std::vector<TLWELvl1> pred_pred_cres(rows);
  auto date_bits = data[0].commitdate().bits;
  // for orderpriority
  std::vector<TLWELvl1> pred_orderpriority1_cres(rows),
      pred_orderpriority2_cres(rows);
  std::vector<TLWELvl1> pred_orderpriority_cres(rows);
  auto orderpriority_bits = data[0].orderpriority().bits;
  // for shipmode
  std::vector<std::vector<TLWELvl1>> pred_group_cres(
      groupby_num, std::vector<TLWELvl1>(rows));
  auto shipmode_bits = data[0].shipmode().bits;

  // ==== find cache filters
  // predicates
  for (int i = 0; i < filters_name.size(); i++) {
    cm.find(filters_name[i], filters[i], metas[i]);
  }
  // groupby
  size_t col = 0, row = 0;
  for (int i = 0; i < gfilters_name.size(); i++, row++) {
    std::vector<CacheFilter> tmp;
    cm.find(gfilters_name[i], tmp, gmetas[i]);
    assert(tmp.size() < 2);
    if (!tmp.empty())
      gfilters[col][row] = tmp[0];
    else
      gfilters[col][row] = CacheFilter();
    // update col and row
    if (row == gfilters[col].size() - 1) {
      col++;
      row = -1;
    }
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

  // l_commitdate < l_receiptdate
  bool commitdate_operated = !!metas[2].get_density();
  HomFastComp<Lvl02, LT, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_commitdate_cres.data(), commitdate_ciphers.data(), receiptdate_ciphers.data(),
      date_bits, metas[2].get_density(), rows, filter_time);
  commitdate_operated = tfhe_correction(ctx, filters[2], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_commitdate_cres.data(), rows, tfhe_correction_time) || commitdate_operated;

  // l_shipdate < l_commitdate
  bool shipdate_operated = !!metas[3].get_density();
  HomFastComp<Lvl02, LT, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_shipdate_cres.data(), shipdate_ciphers.data(), commitdate_ciphers.data(),
      date_bits, metas[3].get_density(), rows, filter_time);
  shipdate_operated = tfhe_correction(ctx, filters[3], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_shipdate_cres.data(), rows, tfhe_correction_time) || shipdate_operated;

  // l_receiptdate >= date
  HomFastComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_receiptdate1_cres.data(), receiptdate_ciphers.data(), pred_cipher_receiptdate1.data(),
      date_bits, metas[0].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[0], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_receiptdate1_cres.data(), rows, tfhe_correction_time);

  // l_receiptdate < date
  HomFastComp<Lvl02, LT, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_receiptdate2_cres.data(), receiptdate_ciphers.data(), pred_cipher_receiptdate2.data(),
      date_bits, metas[1].get_density(), rows, filter_time);
  tfhe_correction(ctx, filters[1], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_receiptdate2_cres.data(), rows, tfhe_correction_time);

  // AND all predicates
  if (commitdate_operated) {
    HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_pred_cres.data(), pred_commitdate_cres.data(), pred_shipdate_cres.data(),
        rows, filter_time);
  }
  if (shipdate_operated) {
    HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_pred_cres.data(), pred_pred_cres.data(), pred_receiptdate1_cres.data(),
        rows, filter_time);
  }
  HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_pred_cres.data(), pred_pred_cres.data(), pred_receiptdate2_cres.data(),
      rows, filter_time);

  // orderpriority = '1-URGENT' or orderpriority = '2-HIGH'
  bool exists_orderpriority = !!metas[4].get_density();
  if (exists_orderpriority) {
    HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
        pred_orderpriority1_cres.data(), orderpriority_ciphers.data(), pred_cipher_orderpriority1.data(),
        orderpriority_bits, rows, filter_time);
    HomComp<Lvl02, EQ, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
        pred_orderpriority2_cres.data(), orderpriority_ciphers.data(), pred_cipher_orderpriority2.data(),
        orderpriority_bits, rows, filter_time);
    HomOR<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_orderpriority_cres.data(), pred_orderpriority1_cres.data(), pred_orderpriority2_cres.data(),
        rows, filter_time);
  } else {
    exists_orderpriority = tfhe_correction(ctx, filters[4], pt_bs_data_lvl1, pt_tlwe_data_lvl1,
      pred_orderpriority_cres.data(), rows, tfhe_correction_time) || exists_orderpriority;
  }
  if (exists_orderpriority) {
    HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_pred_cres.data(), pred_pred_cres.data(), pred_orderpriority_cres.data(),
        rows, filter_time);
  }

  std::vector<size_t> indices(gfilters.size(), 0);

  // shipmode in ('FOB', 'AIR'), group by l_shipmode
  for (size_t i = 0; i < groupby_num; i++) {
    auto &group_filter = gfilters[0][indices[0]];
    auto &group_meta = gmetas[indices[0]];
    bool group_operated = !!group_meta.get_density();
    HomFastComp<Lvl01, EQ, LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_group_cres[i].data(), shipmode_ciphers.data(), pred_cipher_shipmode[i].data(),
        shipmode_bits, group_meta.get_density(), rows, filter_time);
    group_operated = tfhe_correction(group_filter, pt_tlwe_data_lvl1,
      pred_group_cres[i].data(), rows, tfhe_correction_time) || group_operated;

    if (group_operated) {
      HomAND<ARITHMETIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
          pred_cres[i].data(), pred_pred_cres.data(), pred_group_cres[i].data(),
          rows, filter_time);
    }

    // Move to next
    for (size_t k = gfilters.size(); k-- > 0;) {
      if (++indices[k] < gfilters[k].size()) {
        break;
      }
      indices[k] = 0;
    }
  }

  // check the results
  if (!NOCHECK) {
    std::vector<uint32_t> pred_commitdate_dres(rows), pred_shipdate_dres(rows),
        pred_receiptdate1_dres(rows), pred_receiptdate2_dres(rows),
        pred_exsits_orderpriority_dres(rows);
    std::vector<std::vector<uint32_t>> pred_shipmode_dres(
        groupby_num, std::vector<uint32_t>(rows));

    for (size_t i = 0; i < rows; i++) {
      pred_commitdate_dres[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_commitdate_cres[i], sk.key.lvl1);
      pred_shipdate_dres[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_shipdate_cres[i], sk.key.lvl1);
      pred_receiptdate1_dres[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_receiptdate1_cres[i], sk.key.lvl1);
      pred_receiptdate2_dres[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_receiptdate2_cres[i], sk.key.lvl1);
      pred_exsits_orderpriority_dres[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_orderpriority_cres[i], sk.key.lvl1);
      for (size_t j = 0; j < groupby_num; j++) {
        pred_shipmode_dres[j][i] =
            TFHEpp::tlweSymDecrypt<Lvl1>(pred_group_cres[j][i], sk.key.lvl1);
        if (pred_shipmode_dres[j][i] != pred_group_res[j][i]) {
          std::cout << "Predicate shipmode Error: " << pred_shipmode_dres[j][i]
                    << " " << pred_group_res[j][i] << std::endl;
        }
      }

      if (pred_commitdate_dres[i] != pred_commitdate[i]) {
        std::cout << "Predicate commitdate Error: " << pred_commitdate_dres[i]
                  << " " << pred_commitdate[i] << std::endl;
      }
      if (pred_shipdate_dres[i] != pred_shipdate[i]) {
        std::cout << "Predicate shipdate Error: " << pred_shipdate_dres[i] << " "
                  << pred_shipdate[i] << std::endl;
      }
      if (pred_receiptdate1_dres[i] != pred_receiptdate1[i]) {
        std::cout << "Predicate receiptdate1 Error: " << pred_receiptdate1_dres[i]
                  << " " << pred_receiptdate1[i] << std::endl;
      }
      if (pred_receiptdate2_dres[i] != pred_receiptdate2[i]) {
        std::cout << "Predicate receiptdate2 Error: " << pred_receiptdate2_dres[i]
                  << " " << pred_receiptdate2[i] << std::endl;
      }
      if (pred_exsits_orderpriority_dres[i] != pred_orderpriority[i]) {
        std::cout << "Predicate orderpriority Error: "
                  << pred_exsits_orderpriority_dres[i] << " " << pred_orderpriority[i]
                  << std::endl;
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
  std::vector<double> count_data(rows);
  // packed ciphertext
  PhantomCiphertext count_cipher;
  // sum result ciphertext
  std::vector<PhantomCiphertext> high_line_count(groupby_num);
  std::vector<DataPack> table = {
      {count_data, count_cipher, high_line_count}};

  for (size_t i = 0; i < rows; i++) {
    count_data[i] = 1.0;
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
  std::vector<char> _shipmode = {'1', '2', '3'};
  int _shipmode_size = 2;
  for (size_t i = 0; i < rows; i++) {
    data[i].init(_shipmode);
  }
  query_data.init(_shipmode, _shipmode_size);

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
    "receiptdate1", "receiptdate2", "commitdate", "shipdate", "orderpriority"
  };
  std::vector<std::vector<CacheFilter>> filters(filters_name.size());
  std::vector<CacheMetadata<T>> metas = {
      CacheMetadata<T>(CompLogic::GE, (T)query_data.receiptdate1().value),
      CacheMetadata<T>(CompLogic::LT, (T)query_data.receiptdate2().value),
      CacheMetadata<T>(CompLogic::NE, (T)0),
      CacheMetadata<T>(CompLogic::NE, (T)0),
      CacheMetadata<T>(CompLogic::NE, (T)0),
  };

  std::vector<std::string> gfilters_name;
  std::vector<std::vector<CacheFilter>> gfilters(1);
  gfilters[0] = std::vector<CacheFilter>(_shipmode_size);
  std::vector<CacheMetadata<T>> gmetas;
  for (size_t i = 0; i < _shipmode_size; ++i) {
    gfilters_name.push_back("shipmode");
    gmetas.push_back(
        CacheMetadata<T>(CompLogic::EQ, (T)query_data.shipmode()[i].value));
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
  argparse::ArgumentParser program("tpch_q12");

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
