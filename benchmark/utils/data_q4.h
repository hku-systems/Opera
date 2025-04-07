#pragma once

#include <variant>
#include "utils.h"

class DataRecord {
  using ValueD = Value<double>;
  using ValueC = Value<char>;
  using ValueL = Value<Lvl1::T>;
  using VariantType = std::variant<ValueD, ValueC, ValueL>;

 public:
  std::array<VariantType, 8> values;

  ValueC& orderstatus() { return std::get<ValueC>(values[0]); }
  ValueD& totalprice() { return std::get<ValueD>(values[1]); }
  ValueL& orderdate() { return std::get<ValueL>(values[2]); }
  ValueL& orderpriority() { return std::get<ValueL>(values[3]); }
  ValueL& clerk() { return std::get<ValueL>(values[4]); }
  ValueL& shippriority() { return std::get<ValueL>(values[5]); }

  ValueL& commitdate() { return std::get<ValueL>(values[6]); }
  ValueL& receiptdate() { return std::get<ValueL>(values[7]); }

  DataRecord() {
    values = {ValueC(0, 8),  ValueD(0, 32), ValueL(0, 26),
              ValueL(0, 8), ValueL(0, 20), ValueL(0, 20),
              ValueL(0, 26), ValueL(0, 26)};
  }
  ~DataRecord() {}

  void init(int orderpriority) {
    randomize(orderpriority);
  }

 private:
  void randomize(int m) {
    std::random_device seed_gen;
    std::mt19937 engine(seed_gen());
    std::uniform_int_distribution<char> orderstatus_message(0, 2);
    std::uniform_real_distribution<double> totalprice_message(1, 5000);
    std::uniform_int_distribution<Lvl1::T> orderpriority_message(0, m - 1);
    std::uniform_int_distribution<Lvl1::T> clerk_message(0, 1000);
    std::uniform_int_distribution<Lvl1::T> shippriority_message(0, 1000);
    orderstatus().value = orderstatus_message(engine);
    totalprice().value = totalprice_message(engine);
    orderdate().value = generate_date(19920101, 19981231);
    orderpriority().value = orderpriority_message(engine);
    clerk().value = clerk_message(engine);
    shippriority().value = shippriority_message(engine);
    commitdate().value = generate_date(19920101, 19981231);
    receiptdate().value = generate_date(19981231, 19991231);
  }
};


class QueryRequest {
  using QDataL = QueryData<Lvl1::T>;
  using QDataVL = std::vector<QueryData<Lvl1::T>>;
  using VariantType1 = std::variant<QDataL>;
  using VariantType2 = std::variant<QDataVL>;

 public:
  // QueryData<Lvl1::T> orderdate1;
  // QueryData<Lvl1::T> orderdate2;
  // std::vector<QueryData<Lvl1::T>> orderpriority;
  std::array<VariantType1, 2> predicates;
  std::array<VariantType2, 1> groupby;
  QDataL& orderdate1() { return std::get<QDataL>(predicates[0]); }
  QDataL& orderdate2() { return std::get<QDataL>(predicates[1]); }
  QDataVL& orderpriority() { return std::get<QDataVL>(groupby[0]); }

 public:
  QueryRequest() {
    predicates = {QDataL(), QDataL()};
    groupby = {QDataVL()};
  }
  ~QueryRequest() {}

  void init(int orderpriority_size) {
    randomize();
    generateGroupBy(orderpriority_size);
  }

 public:
  int pred_num() { return predicates.size(); }
  int groupby_num() { return orderpriority().size(); }
  std::vector<int> group_index(int index) {
    int i = index % orderpriority().size();
    return {i};
  }

 private:
  void randomize() {
    auto date = generate_date(19920101, 19981231);
    orderdate1().value = date;
    orderdate2().value = data_add(date, 3 * 100); // + 3months
  }

  void generateGroupBy(int m) {
    orderpriority().resize(m);
    for (size_t i = 0; i < m; i++) orderpriority()[i].value = i;
  }
};
