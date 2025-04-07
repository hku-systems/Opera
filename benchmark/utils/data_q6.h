#pragma once

#include <variant>
#include "utils.h"
#include "zipfian_int_distribution.h"

constexpr int scale_double = 1000;

struct DataRecord {
  using ValueD = Value<double>;
  using ValueC = Value<char>;
  using ValueL = Value<Lvl1::T>;
  using VariantType = std::variant<ValueD, ValueC, ValueL>;

  public:
  std::array<VariantType, 9> values;
  const int double_scale = scale_double;

  ValueD& quantity() { return std::get<ValueD>(values[0]); }
  ValueD& extendedprice() { return std::get<ValueD>(values[1]); }
  ValueD& discount() { return std::get<ValueD>(values[2]); }
  ValueD& tax() { return std::get<ValueD>(values[3]); }
  ValueC& returnflag() { return std::get<ValueC>(values[4]); }
  ValueC& linestatus() { return std::get<ValueC>(values[5]); }
  ValueL& shipdate() { return std::get<ValueL>(values[6]); }
  ValueL& commitdate() { return std::get<ValueL>(values[7]); }
  ValueL& receiptdate() { return std::get<ValueL>(values[8]); }

  DataRecord(uint32_t shipdate_bits) {
    values = {ValueD(0, 16), ValueD(0, 10), ValueD(0, 12),
      ValueD(0, 4),  ValueC(0, 6),  ValueC(0, 6),
      ValueL(0, shipdate_bits), ValueL(0, 26), ValueL(0, 26)};
  }

  DataRecord() {
    values = {ValueD(0, 16), ValueD(0, 10), ValueD(0, 12),
              ValueD(0, 4),  ValueC(0, 6),  ValueC(0, 6),
              ValueL(0, 26), ValueL(0, 26), ValueL(0, 26)};
  }
  ~DataRecord() {}

  void init() {
    randomize();
  }

  private:
  void randomize() {
    std::random_device seed_gen;
    std::default_random_engine engine(seed_gen());
    std::uniform_real_distribution<double> quantity_message(1, 50);
    std::uniform_real_distribution<double> extendedprice_message(1, 100);
    std::uniform_real_distribution<double> discount_message(0, 0.1);
    std::uniform_real_distribution<double> tax_message(0, 0.1);
    std::uniform_int_distribution<char> returnflag_message(0, 1);
    std::uniform_int_distribution<char> linestatus_message(0, 1);
    quantity().set_value((Lvl1::T)(quantity_message(engine) * scale_double));
    extendedprice().set_value(extendedprice_message(engine));
    discount().set_value((Lvl1::T)(discount_message(engine) * scale_double));
    tax().set_value(tax_message(engine));
    returnflag().set_value(returnflag_message(engine));
    linestatus().set_value(linestatus_message(engine));
    shipdate().set_value(generate_date(20200101, 20221231));
    commitdate().set_value(generate_date(20200101, 20221231));
    receiptdate().set_value(generate_date(20200101, 20221231));
  }
};

struct QueryRequest {
  using QDataL = QueryData<Lvl1::T>;
  using QDataC = std::vector<QueryData<char>>;
  using VariantType1 = std::variant<QDataL>;
  using VariantType2 = std::variant<QDataC>;

 public:
  std::array<VariantType1, 5> predicates;
  std::array<VariantType2, 0> groupby;
  QDataL& shipdate1() { return std::get<QDataL>(predicates[0]); }
  QDataL& shipdate2() { return std::get<QDataL>(predicates[1]); }
  QDataL& discount1() { return std::get<QDataL>(predicates[2]); }
  QDataL& discount2() { return std::get<QDataL>(predicates[3]); }
  QDataL& quantity() { return std::get<QDataL>(predicates[4]); }

  bool zipf = false;
 public:
  QueryRequest() : QueryRequest(false) {}
  QueryRequest(bool zipf) : zipf(zipf), predicates({QDataL()}) {
    engine = std::make_shared<std::mt19937>(std::random_device()());
  }
  QueryRequest(bool zipf, int seed) : zipf(zipf), predicates({QDataL()}) {
    engine = std::make_shared<std::mt19937>(seed);
  }
  ~QueryRequest() {}

  void init() {
    randomize();
    generateGroupBy();
  }

 public:
  int pred_num() { return predicates.size(); }
  int groupby_num() { return 1; }
  std::vector<int> group_index(int index) { return {0}; }

 private:
  std::shared_ptr<std::mt19937> engine;

 private:
  void randomize() {
    Lvl1::T _shipdate, _discount, _quantity;
    if (zipf) {
      zipfian_int_distribution<int> shipdate_message(20200101, 20221231, 0.8);
      zipfian_int_distribution<int> quantity_message(24 * scale_double,
                                                     50 * scale_double, 0.8);
      zipfian_int_distribution<int> discount_message(0 * scale_double,
                                                     0.1 * scale_double, 0.8);
      _shipdate = shipdate_message(*engine);
      _discount = quantity_message(*engine);
      _quantity = discount_message(*engine);
    } else {
      std::uniform_real_distribution<double> quantity_message(24, 50);
      std::uniform_real_distribution<double> discount_message(0, 0.1);
      _shipdate = generate_date(20200101, 20221231);
      _discount = (Lvl1::T)(discount_message(*engine) * scale_double);
      _quantity = (Lvl1::T)(quantity_message(*engine) * scale_double);
    }
    shipdate1().value = _shipdate;
    shipdate2().value = data_add(_shipdate, 1 * 10000);  // + 1year
    discount1().value = _discount;
    discount2().value = _discount + 20;
    quantity().value = _quantity;
  }

  void generateGroupBy() {}
};
