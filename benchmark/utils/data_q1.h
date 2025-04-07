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

  ValueD& quantity() { return std::get<ValueD>(values[0]); }
  ValueD& extendedprice() { return std::get<ValueD>(values[1]); }
  ValueD& discount() { return std::get<ValueD>(values[2]); }
  ValueD& tax() { return std::get<ValueD>(values[3]); }
  ValueC& returnflag() { return std::get<ValueC>(values[4]); }
  ValueC& linestatus() { return std::get<ValueC>(values[5]); }
  ValueL& shipdate() { return std::get<ValueL>(values[6]); }
  ValueL& commitdate() { return std::get<ValueL>(values[7]); }
  ValueL& receiptdate() { return std::get<ValueL>(values[8]); }

  DataRecord() {
    values = {ValueD(0, 6),  ValueD(0, 10), ValueD(0, 4),
              ValueD(0, 4),  ValueC(0, 6),  ValueC(0, 6),
              ValueL(0, 26), ValueL(0, 26), ValueL(0, 26)};
  }
  ~DataRecord() {}

  void init(int returnflag_size, int linestatus_size) {
    randomize(returnflag_size, linestatus_size);
  }

 private:
  void randomize(int m, int n) {
    std::random_device seed_gen;
    std::mt19937 engine(seed_gen());
    std::uniform_real_distribution<double> quantity_message(1, 50);
    std::uniform_real_distribution<double> extendedprice_message(1, 100);
    std::uniform_real_distribution<double> discount_message(0, 0.1);
    std::uniform_real_distribution<double> tax_message(0, 0.1);
    std::uniform_int_distribution<char> returnflag_message(0, m - 1);
    std::uniform_int_distribution<char> linestatus_message(0, n - 1);
    quantity().set_value(quantity_message(engine));
    extendedprice().set_value(extendedprice_message(engine));
    discount().set_value(discount_message(engine));
    tax().set_value(tax_message(engine));
    returnflag().set_value(returnflag_message(engine));
    linestatus().set_value(linestatus_message(engine));
    shipdate().set_value(generate_date(20200101, 20221231));
    commitdate().set_value(generate_date(20200101, 20221231));
    receiptdate().set_value(generate_date(20200101, 20221231));
  }
};

class QueryRequest {
  using QDataL = QueryData<Lvl1::T>;
  using QDataC = std::vector<QueryData<char>>;
  using VariantType1 = std::variant<QDataL>;
  using VariantType2 = std::variant<QDataC>;

 public:
  // QueryData<Lvl1::T> shipdate;
  // std::vector<QueryData<char>> returnflag;
  // std::vector<QueryData<char>> linestatus;
  std::array<VariantType1, 1> predicates;
  std::array<VariantType2, 2> groupby;
  QDataL& shipdate() { return std::get<QDataL>(predicates[0]); }
  QDataC& returnflag() { return std::get<QDataC>(groupby[0]); }
  QDataC& linestatus() { return std::get<QDataC>(groupby[1]); }

 public:
  QueryRequest() {
    predicates = {QDataL()};
    groupby = {QDataC(), QDataC()};
  }
  ~QueryRequest() {}

  void init(int returnflag_size, int linestatus_size) {
    randomize();
    generateGroupBy(returnflag_size, linestatus_size);
  }

 public:
  int pred_num() { return predicates.size(); }
  int groupby_num() { return returnflag().size() * linestatus().size(); }
  std::vector<int> group_index(int index) {
    int i = index / returnflag().size();  // line status
    int j = index % returnflag().size();  // return flag
    return {i, j};
  }

 private:
  void randomize() { shipdate().value = generate_date(20200101, 20221231); }

  void generateGroupBy(int m, int n) {
    returnflag().resize(m);
    linestatus().resize(n);
    for (size_t i = 0; i < m; i++) returnflag()[i].value = i;
    for (size_t i = 0; i < n; i++) linestatus()[i].value = i;
  }
};
