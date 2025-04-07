#include <opera.h>
#include <phantom.h>
#include <chrono>
#include <thread>
#include "data_q1.h"

using namespace cuTFHEpp;
using namespace opera;
using namespace std;

bool FAST_COMP = true;
bool CACHE_ENABLED = true;
bool NOCHECK = true;

/***
 * TPC-H Query 1 modified
  select
      l_returnflag,
      l_linestatus,
      sum(l_quantity) as sum_qty,
      sum(l_extendedprice) as sum_base_price,
      sum(l_extendedprice * (1 - l_discount)) as sum_disc_price,
      sum(l_extendedprice * (1 - l_discount) * (1 + l_tax)) as sum_charge,
      sum(l_discount) as sum_disc,
      count(*) as count_order
  from
      lineitem
  where
      l_shipdate <= date '1998-12-01' - interval '120' day
  group by
      l_returnflag,
      l_linestatus

    consider data encode by [yyyymmdd], 23 bits,
    group by $m$ types of l_returnflag, $n$ types of l_linestatus
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
  std::vector<TLWELvl1> returnflag_ciphers(rows), linestatus_ciphers(rows);
  std::vector<TLWELvl2> ship_ciphers(rows);
  for (size_t i = 0; i < rows; i++) {
    auto row_data = data[i];
    returnflag_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl1>(
        row_data.returnflag().value, Lvl1::α,
        pow(2., row_data.returnflag().scale_bits<Lvl1>()), sk.key.get<Lvl1>());
    linestatus_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl1>(
        row_data.linestatus().value, Lvl1::α,
        pow(2., row_data.linestatus().scale_bits<Lvl1>()), sk.key.get<Lvl1>());
    ship_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.shipdate().value, Lvl2::α,
        pow(2., row_data.shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  }

  // Encrypt Predicate values
  std::cout << "Encrypting Predicate Values..." << std::endl;

  // check if the predicate is correct
  auto groupby_num = query_data.groupby_num();
  // pred_ship[rows]
  std::vector<uint32_t> pred_ship_res(rows, 0);
  // pred_group[rows][groupby_num]
  std::vector<std::vector<uint32_t>> pred_group_res(
      groupby_num, std::vector<uint32_t>(rows, 0));
  // pred_res[groupby_num][rows]
  pred_res.resize(groupby_num, std::vector<uint32_t>(rows, 1));
  pred_cres.resize(groupby_num, std::vector<TLWELvl1>(rows));

  // pred_part & pred_group
  for (size_t i = 0; i < rows; i++) {
    auto ship_record = query_data.shipdate();
    pred_ship_res[i] = !!(data[i].shipdate().value <= ship_record.value);
    for (size_t j = 0; j < groupby_num; j++) {
      auto index = query_data.group_index(j);
      pred_group_res[j][i] = (data[i].linestatus().value ==
                              query_data.linestatus()[index[0]].value) &&
                             (data[i].returnflag().value ==
                              query_data.returnflag()[index[1]].value);
    }
  }
  // pred_res
  for (size_t i = 0; i < groupby_num; i++) {
    for (size_t j = 0; j < rows; j++) {
      pred_res[i][j] = pred_group_res[i][j] & pred_ship_res[j];
    }
  }

  // Encrypt Predicates
  std::vector<TLWELvl2> pred_cipher_ship(rows);
  // pred_cipher_group
  std::vector<std::vector<TLWELvl1>> pred_cipher_linestatus;
  std::vector<std::vector<TLWELvl1>> pred_cipher_returnflag;
  // encrypt predicate part
  auto cipher_ship = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.shipdate().value, Lvl2::α,
      pow(2., data[0].shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  for (size_t i = 0; i < rows; i++) {
    pred_cipher_ship[i] = cipher_ship;
  }
  // encrypt group by part
  double linestatus_scale = pow(2., data[0].linestatus().scale_bits<Lvl1>());
  auto linestatus_group = query_data.linestatus();
  pred_cipher_linestatus.resize(linestatus_group.size());
  for (size_t i = 0; i < linestatus_group.size(); i++) {
    auto temp = TFHEpp::tlweSymInt32Encrypt<Lvl1>(linestatus_group[i].value, Lvl1::α,
                                          linestatus_scale, sk.key.get<Lvl1>());
    pred_cipher_linestatus[i].resize(rows);
    for (size_t j = 0; j < rows; j++)
      pred_cipher_linestatus[i][j] = temp;
  }
  double returnflag_scale = pow(2., data[0].returnflag().scale_bits<Lvl1>());
  auto returnflag_group = query_data.returnflag();
  pred_cipher_returnflag.resize(returnflag_group.size());
  for (size_t i = 0; i < returnflag_group.size(); i++) {
    auto temp = TFHEpp::tlweSymInt32Encrypt<Lvl1>(returnflag_group[i].value, Lvl1::α,
                                          returnflag_scale, sk.key.get<Lvl1>());
    pred_cipher_returnflag[i].resize(rows);
    for (size_t j = 0; j < rows; j++)
      pred_cipher_returnflag[i][j] = temp;
  }

  // Predicate Evaluation
  std::cout << "Start Predicate Evaluation..." << std::endl;
  std::vector<TLWELvl1> pred_ship_cres(rows);
  auto ship_bits = data[0].shipdate().bits;
  std::vector<std::vector<TLWELvl1>> pred_group_cres1(
      groupby_num, std::vector<TLWELvl1>(rows));
  std::vector<std::vector<TLWELvl1>> pred_group_cres2(
      groupby_num, std::vector<TLWELvl1>(rows));
  std::vector<std::vector<TLWELvl1>> pred_group_cres(
      groupby_num, std::vector<TLWELvl1>(rows));
  auto linestatus_bits = data[0].linestatus().bits;
  auto returnflag_bits = data[0].returnflag().bits;

  Pointer<BootstrappingData<Lvl02>> pt_bs_data(rows);
  auto &pt_bs_data_lvl1 = pt_bs_data.template safe_cast<BootstrappingData<Lvl01>>();

  std::vector<Pointer<cuTLWE<Lvl2>>> tlwe_data;
  tlwe_data.reserve(4);
  for (size_t i = 0; i < 4; ++i) tlwe_data.emplace_back(rows);

  Pointer<cuTLWE<Lvl2>> *pt_tlwe_data = tlwe_data.data();
  Pointer<cuTLWE<Lvl1>> *pt_tlwe_data_lvl1 = &pt_tlwe_data->template safe_cast<cuTLWE<Lvl1>>();

  filter_time = 0;

  HomComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_ship_cres.data(), ship_ciphers.data(), pred_cipher_ship.data(),
      ship_bits, rows, filter_time);

  for (size_t j = 0; j < groupby_num; j++) {
    auto index = query_data.group_index(j);
    HomComp<Lvl01, EQ, LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_group_cres1[j].data(), pred_cipher_linestatus[index[0]].data(), linestatus_ciphers.data(),
        linestatus_bits, rows, filter_time);
    HomComp<Lvl01, EQ, LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_group_cres2[j].data(), pred_cipher_returnflag[index[1]].data(), returnflag_ciphers.data(),
        returnflag_bits, rows, filter_time);

    HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_group_cres[j].data(), pred_group_cres1[j].data(), pred_group_cres2[j].data(),
        rows, filter_time);
    HomAND<ARITHMETIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_cres[j].data(), pred_group_cres[j].data(), pred_ship_cres.data(),
        rows, filter_time);
  }

  // check the results
  if (!NOCHECK) {
    std::vector<std::vector<uint32_t>> pred_cres_de(groupby_num,
                                                    std::vector<uint32_t>(rows));
    std::vector<uint32_t> pred_ship_cres_de(rows);
    std::vector<std::vector<uint32_t>> pred_group_cres1_de(
        groupby_num, std::vector<uint32_t>(rows));
    std::vector<std::vector<uint32_t>> pred_group_cres2_de(
        groupby_num, std::vector<uint32_t>(rows));
    std::vector<std::vector<uint32_t>> pred_group_cres_de(
        groupby_num, std::vector<uint32_t>(rows));
    for (size_t i = 0; i < rows; i++) {
      pred_ship_cres_de[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_ship_cres[i], sk.key.lvl1);
      for (size_t j = 0; j < groupby_num; j++) {
        pred_cres_de[j][i] = TFHEpp::tlweSymInt32Decrypt<Lvl1>(
            pred_cres[j][i], pow(2., 31), sk.key.get<Lvl1>());
        pred_group_cres1_de[j][i] =
            TFHEpp::tlweSymDecrypt<Lvl1>(pred_group_cres1[j][i], sk.key.lvl1);
        pred_group_cres2_de[j][i] =
            TFHEpp::tlweSymDecrypt<Lvl1>(pred_group_cres2[j][i], sk.key.lvl1);
        pred_group_cres_de[j][i] =
            TFHEpp::tlweSymDecrypt<Lvl1>(pred_group_cres[j][i], sk.key.lvl1);
      }
    }

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

    std::cout << "Predicate Error: " << error_time << std::endl;
  }

  std::cout << "Filter Time : " << filter_time << "ms" << std::endl;
}

void predicate_evaluation_cache(std::vector<std::vector<TLWELvl1>> &pred_cres,
                          std::vector<std::vector<uint32_t>> &pred_res,
                          std::vector<DataRecord> &data,
                          QueryRequest &query_data,
                          TFHESecretKey &sk,
                          TFHEEvalKey &ek,
                          CacheManager<Lvl1> &cm,
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
  std::vector<TLWELvl1> returnflag_ciphers(rows), linestatus_ciphers(rows);
  std::vector<TLWELvl2> ship_ciphers(rows);
  for (size_t i = 0; i < rows; i++) {
    auto row_data = data[i];
    returnflag_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl1>(
        row_data.returnflag().value, Lvl1::α,
        pow(2., row_data.returnflag().scale_bits<Lvl1>()), sk.key.get<Lvl1>());
    linestatus_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl1>(
        row_data.linestatus().value, Lvl1::α,
        pow(2., row_data.linestatus().scale_bits<Lvl1>()), sk.key.get<Lvl1>());
    ship_ciphers[i] = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
        row_data.shipdate().value, Lvl2::α,
        pow(2., row_data.shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  }

  // Encrypt Predicate values
  std::cout << "Encrypting Predicate Values..." << std::endl;

  // check if the predicate is correct
  auto groupby_num = query_data.groupby_num();
  // pred_ship[rows]
  std::vector<uint32_t> pred_ship_res(rows, 0);
  // pred_group[rows][groupby_num]
  std::vector<std::vector<uint32_t>> pred_group_res(
      groupby_num, std::vector<uint32_t>(rows, 0));
  // pred_res[groupby_num][rows]
  pred_res.resize(groupby_num, std::vector<uint32_t>(rows, 1));
  pred_cres.resize(groupby_num, std::vector<TLWELvl1>(rows));

  // pred_part & pred_group
  for (size_t i = 0; i < rows; i++) {
    auto ship_record = query_data.shipdate();
    pred_ship_res[i] = !!(data[i].shipdate().value <= ship_record.value);
    for (size_t j = 0; j < groupby_num; j++) {
      auto index = query_data.group_index(j);
      pred_group_res[j][i] = (data[i].linestatus().value ==
                              query_data.linestatus()[index[0]].value) &&
                             (data[i].returnflag().value ==
                              query_data.returnflag()[index[1]].value);
    }
  }
  // pred_res
  for (size_t i = 0; i < groupby_num; i++) {
    for (size_t j = 0; j < rows; j++) {
      pred_res[i][j] = pred_group_res[i][j] & pred_ship_res[j];
    }
  }

  std::vector<Lvl1::T> data_shipdate;
  // ==== generate cache filters
  std::transform(data.begin(), data.end(), std::back_inserter(data_shipdate),
                 [](DataRecord &item) { return item.shipdate().value; });
  cm.generate(filters_name[0], data_shipdate, metas[0]);

  size_t i = 0;
  std::vector<Lvl1::T> data_linestatus, data_returnflag;
  std::transform(data.begin(), data.end(), std::back_inserter(data_linestatus),
                 [](DataRecord &item) { return item.linestatus().value; });
  std::transform(data.begin(), data.end(), std::back_inserter(data_returnflag),
                 [](DataRecord &item) { return item.returnflag().value; });
  for (size_t j = 0; j < gfilters[0].size(); ++i, ++j)
    cm.generate(gfilters_name[i], data_linestatus, gmetas[i]);
  for (size_t j = 0; j < gfilters[1].size(); ++i, ++j)
    cm.generate(gfilters_name[i], data_returnflag, gmetas[i]);
  // ==== end of cache filter generation

  // Encrypt Predicates
  std::vector<TLWELvl2> pred_cipher_ship(rows);
  // pred_cipher_group
  std::vector<std::vector<TLWELvl1>> pred_cipher_linestatus;
  std::vector<std::vector<TLWELvl1>> pred_cipher_returnflag;
  // encrypt predicate part
  auto cipher_ship = TFHEpp::tlweSymInt32Encrypt<Lvl2>(
      query_data.shipdate().value, Lvl2::α,
      pow(2., data[0].shipdate().scale_bits<Lvl2>()), sk.key.get<Lvl2>());
  for (size_t i = 0; i < rows; i++) {
    pred_cipher_ship[i] = cipher_ship;
  }
  // encrypt group by part
  double linestatus_scale = pow(2., data[0].linestatus().scale_bits<Lvl1>());
  auto linestatus_group = query_data.linestatus();
  pred_cipher_linestatus.resize(linestatus_group.size());
  for (size_t i = 0; i < linestatus_group.size(); i++) {
    auto temp = TFHEpp::tlweSymInt32Encrypt<Lvl1>(linestatus_group[i].value, Lvl1::α,
                                          linestatus_scale, sk.key.get<Lvl1>());
    pred_cipher_linestatus[i].resize(rows);
    for (size_t j = 0; j < rows; j++)
      pred_cipher_linestatus[i][j] = temp;
  }
  double returnflag_scale = pow(2., data[0].returnflag().scale_bits<Lvl1>());
  auto returnflag_group = query_data.returnflag();
  pred_cipher_returnflag.resize(returnflag_group.size());
  for (size_t i = 0; i < returnflag_group.size(); i++) {
    auto temp = TFHEpp::tlweSymInt32Encrypt<Lvl1>(returnflag_group[i].value, Lvl1::α,
                                          returnflag_scale, sk.key.get<Lvl1>());
    pred_cipher_returnflag[i].resize(rows);
    for (size_t j = 0; j < rows; j++)
      pred_cipher_returnflag[i][j] = temp;
  }

  // Predicate Evaluation
  std::cout << "Start Predicate Evaluation..." << std::endl;
  std::vector<TLWELvl1> pred_ship_cres(rows);
  auto ship_bits = data[0].shipdate().bits;
  std::vector<std::vector<TLWELvl1>> pred_group_cres1(
      groupby_num, std::vector<TLWELvl1>(rows));
  std::vector<std::vector<TLWELvl1>> pred_group_cres2(
      groupby_num, std::vector<TLWELvl1>(rows));
  std::vector<std::vector<TLWELvl1>> pred_group_cres(
      groupby_num, std::vector<TLWELvl1>(rows));
  auto linestatus_bits = data[0].linestatus().bits;
  auto returnflag_bits = data[0].returnflag().bits;

  // ==== find cache filters
  // predicates
  for (int i = 0; i < filters_name.size(); i++) {
    cm.find(filters_name[i], filters[i], metas[i]);
  }
  // groupby
  int col = 0, row = 0;
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

  HomFastComp<Lvl02, LE, LOGIC>(ctx, pt_bs_data, pt_tlwe_data,
      pred_ship_cres.data(), ship_ciphers.data(), pred_cipher_ship.data(),
      ship_bits, metas[0].get_density(), rows, filter_time);

  tfhe_correction(ctx, filters[0], pt_bs_data_lvl1, pt_tlwe_data_lvl1, pred_ship_cres.data(),
      rows, tfhe_correction_time);

  std::vector<size_t> indices(gfilters.size(), 0);
  for (size_t j = 0; j < groupby_num; j++) {
    auto index = query_data.group_index(j);

    // group by - linestatus
    auto linestatus_filters = gfilters[0][indices[0]];
    auto linestatus_metas = gmetas[indices[0]];
    bool operated_linestatus = !!linestatus_metas.get_density();

    HomFastComp<Lvl01, EQ, LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_group_cres1[j].data(), pred_cipher_linestatus[index[0]].data(), linestatus_ciphers.data(),
        linestatus_bits, linestatus_metas.get_density(), rows, filter_time);
    operated_linestatus = tfhe_correction(
        linestatus_filters, pt_tlwe_data_lvl1, pred_group_cres1[j].data(), rows, tfhe_correction_time)
      || operated_linestatus;

    // group by - returnflag
    auto base = gfilters[0].size();
    auto returnflag_filters = gfilters[1][indices[1]];
    auto returnflag_metas = gmetas[base + indices[1]];
    bool operated_returnflag = !!returnflag_metas.get_density();

    HomFastComp<Lvl01, EQ, LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
        pred_group_cres2[j].data(), pred_cipher_returnflag[index[1]].data(), returnflag_ciphers.data(),
        returnflag_bits, returnflag_metas.get_density(), rows, filter_time);
    operated_returnflag = tfhe_correction(
        returnflag_filters, pt_tlwe_data_lvl1, pred_group_cres2[j].data(), rows, tfhe_correction_time)
      || operated_returnflag;

    if (operated_linestatus || operated_returnflag) {
      if (operated_linestatus && operated_returnflag) {
        HomAND<LOGIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
            pred_group_cres[j].data(), pred_group_cres1[j].data(), pred_group_cres2[j].data(),
            rows, filter_time);
      } else {
        pred_group_cres[j] = operated_linestatus ? pred_group_cres1[j]
                                                    : pred_group_cres2[j];
      }
      HomAND<ARITHMETIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
          pred_cres[j].data(), pred_group_cres[j].data(), pred_ship_cres.data(), rows, filter_time);
    } else {
      HomAND<ARITHMETIC>(ctx, pt_bs_data_lvl1, pt_tlwe_data_lvl1,
          pred_cres[j].data(), pred_ship_cres.data(), pred_ship_cres.data(), rows, filter_time);
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
    std::vector<std::vector<uint32_t>> pred_cres_de(groupby_num,
                                                    std::vector<uint32_t>(rows));
    std::vector<uint32_t> pred_ship_cres_de(rows);
    std::vector<std::vector<uint32_t>> pred_group_cres1_de(
        groupby_num, std::vector<uint32_t>(rows));
    std::vector<std::vector<uint32_t>> pred_group_cres2_de(
        groupby_num, std::vector<uint32_t>(rows));
    std::vector<std::vector<uint32_t>> pred_group_cres_de(
        groupby_num, std::vector<uint32_t>(rows));
    for (size_t i = 0; i < rows; i++) {
      pred_ship_cres_de[i] =
          TFHEpp::tlweSymDecrypt<Lvl1>(pred_ship_cres[i], sk.key.lvl1);
      for (size_t j = 0; j < groupby_num; j++) {
        pred_cres_de[j][i] = TFHEpp::tlweSymInt32Decrypt<Lvl1>(
            pred_cres[j][i], pow(2., 31), sk.key.get<Lvl1>());
        pred_group_cres1_de[j][i] =
            TFHEpp::tlweSymDecrypt<Lvl1>(pred_group_cres1[j][i], sk.key.lvl1);
        pred_group_cres2_de[j][i] =
            TFHEpp::tlweSymDecrypt<Lvl1>(pred_group_cres2[j][i], sk.key.lvl1);
        pred_group_cres_de[j][i] =
            TFHEpp::tlweSymDecrypt<Lvl1>(pred_group_cres[j][i], sk.key.lvl1);
      }
    }

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
                 std::vector<DataRecord> &data, size_t rows, PhantomRLWE &rlwe,
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
  std::vector<double> quantity_data(rows), extendedprice_data(rows),
      extendedprice_discount_data(rows), discount_tax_data(rows),
      discount_data(rows);
  // packed ciphertext
  PhantomCiphertext quantity_cipher, extendedprice_cipher,
      extendedprice_discount_cipher, discount_tax_cipher, discount_cipher;
  // sum result ciphertext
  std::vector<PhantomCiphertext> sum_qty(groupby_num),
      sum_base_price(groupby_num), sum_disc_price(groupby_num),
      sum_charge(groupby_num), sum_disc(groupby_num);
  std::vector<DataPack> table = {
      {quantity_data, quantity_cipher, sum_qty},
      {extendedprice_data, extendedprice_cipher, sum_base_price},
      {extendedprice_discount_data, extendedprice_discount_cipher,
       sum_disc_price},
      {discount_tax_data, discount_tax_cipher, sum_charge},
      {discount_data, discount_cipher, sum_disc}};

  for (size_t i = 0; i < rows; i++) {
    quantity_data[i] = data[i].quantity().value;
    extendedprice_data[i] = data[i].extendedprice().value;
    extendedprice_discount_data[i] =
        data[i].extendedprice().value * (1 - data[i].discount().value);
    discount_tax_data[i] = data[i].extendedprice().value *
                           (1 - data[i].discount().value) *
                           (1 + data[i].tax().value);
    discount_data[i] = data[i].discount().value;
  }

  // convert data to ciphertext
  PhantomPlaintext t_plain;
  double qd =
      rlwe.parms.coeff_modulus()[result[0].coeff_modulus_size_ - 1].value();
  for (auto [_data_plaintext, _data_cipher, _sum_cipher] : table) {
    pack_encode(*rlwe.context, _data_plaintext, qd, t_plain, *rlwe.ckks_encoder);
    rlwe.secret_key->encrypt_symmetric(*rlwe.context, t_plain, _data_cipher, false);
  }


  std::cout << "Aggregating quantity, prices and discount .." << std::endl;
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
  int returnflag_size = 2, linestatus_size = 3;
  for (size_t i = 0; i < rows; i++) {
    data[i].init(returnflag_size, linestatus_size);
  }
  query_data.init(returnflag_size, linestatus_size);
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

  std::vector<std::string> filters_name = {"shipdate"};
  std::vector<std::vector<CacheFilter>> filters(filters_name.size());
  std::vector<CacheMetadata<T>> metas = {
      CacheMetadata<T>(CompLogic::LE, (T)query_data.shipdate().value)};

  std::vector<std::string> gfilters_name;
  std::vector<std::vector<CacheFilter>> gfilters(2);
  std::vector<CacheMetadata<T>> gmetas;
  gfilters[0] = std::vector<CacheFilter>(linestatus_size);
  for (size_t i = 0; i < linestatus_size; ++i) {
    gfilters_name.push_back("linestatus");
    gmetas.push_back(CacheMetadata<T>(CompLogic::EQ,
                                 (T)query_data.linestatus()[i].value));
  };
  gfilters[1] = std::vector<CacheFilter>(returnflag_size);
  for (size_t i = 0; i < returnflag_size; ++i) {
    gfilters_name.push_back("returnflag");
    gmetas.push_back(CacheMetadata<T>(CompLogic::EQ,
                                 (T)query_data.returnflag()[i].value));
  };

  double filter_time, conversion_time, tfhe_correction_time, ckks_correction_time, aggregation_time;
  std::vector<std::vector<TLWELvl1>> pred_cres;
  std::vector<std::vector<uint32_t>> pred_res;
  std::vector<PhantomCiphertext> results;

  predicate_evaluation_cache(pred_cres, pred_res, data, query_data, sk, ek,
      cm, filters, filters_name, metas, gfilters, gfilters_name, gmetas, rows, filter_time, tfhe_correction_time);
  rlwe.genLWE2RLWEGaloisKeys();
  conversion(results, pred_cres, pred_res, rlwe, sk, conversion_time, NOCHECK);
  // phantom::util::global_pool()->Release_useless();
  rlwe.genGaloisKeys();
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
  argparse::ArgumentParser program("tpch_q1");

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
