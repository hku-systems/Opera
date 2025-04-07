#pragma once

#include <variant>
#include "utils.h"

class DataRecord {
  using ValueD = Value<double>;
  using ValueC = Value<char>;
  using ValueL = Value<Lvl1::T>;
  using VariantType = std::variant<ValueD, ValueC, ValueL>;

 public:
  std::array<VariantType, 9> values;

  ValueL& shipdate() { return std::get<ValueL>(values[0]); }
  ValueL& revenue() { return std::get<ValueL>(values[1]); }
  ValueL& suppkey() { return std::get<ValueL>(values[2]); }

  DataRecord() {
    values = {ValueL(0, 26), ValueL(0, 26), ValueL(0, 26)};
  }
  ~DataRecord() {}

  void init(int _suppkey_size) {
    randomize(_suppkey_size);
  }

 private:
  void randomize(int _suppkey_size) {
    std::random_device seed_gen;
    std::mt19937 engine(seed_gen());
    std::uniform_int_distribution<Lvl1::T> revenue_message(1, 100);
    std::uniform_int_distribution<Lvl1::T> suppkey_message(0, _suppkey_size - 1);
    revenue().set_value(revenue_message(engine));
    suppkey().set_value(suppkey_message(engine));
    shipdate().set_value(generate_date(20200101, 20221231));
  }
};

class QueryRequest {
  using QDataL = QueryData<Lvl1::T>;
  using QDataVL = std::vector<QueryData<Lvl1::T>>;
  using VariantType1 = std::variant<QDataL>;
  using VariantType2 = std::variant<QDataVL>;

 public:
  std::array<VariantType1, 2> predicates;
  QDataL& shipdate1() { return std::get<QDataL>(predicates[0]); }
  QDataL& shipdate2() { return std::get<QDataL>(predicates[1]); }
  std::array<VariantType2, 1> groupby;
  QDataVL& total_revenue() { return std::get<QDataVL>(groupby[0]); }

 public:
  QueryRequest() {
    predicates = {QDataL(), QDataL()};
    groupby = {QDataVL()};
  }
  ~QueryRequest() {}

  void init(int supplier_size) {
    randomize();
    generateGroupBy(supplier_size);
  }

 private:
  void randomize() {
    auto date = generate_date(20200101, 20221231);
    shipdate1().value = date;
    shipdate2().value = data_add(date, 3 * 100);  // + 3 months
  }

  void generateGroupBy(int _supplier_size) {
    total_revenue().resize(_supplier_size);
    for (size_t i = 0; i < _supplier_size; i++)
      total_revenue()[i].value = i;
  }
};

