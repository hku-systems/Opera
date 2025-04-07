#pragma once

#include <variant>
#include "utils.h"

class DataRecord {
  using ValueD = Value<double>;
  using ValueC = Value<char>;
  using ValueL = Value<Lvl1::T>;
  using VariantType = std::variant<ValueD, ValueC, ValueL>;

 public:
  std::array<VariantType, 5> values;

  ValueC& shipmode() { return std::get<ValueC>(values[0]); }
  ValueL& orderpriority() { return std::get<ValueL>(values[1]); }
  ValueL& commitdate() { return std::get<ValueL>(values[2]); }
  ValueL& shipdate() { return std::get<ValueL>(values[3]); }
  ValueL& receiptdate() { return std::get<ValueL>(values[4]); }

  DataRecord() {
    values = {ValueC(0, 8), ValueL(0, 8),
              ValueL(0, 26), ValueL(0, 26), ValueL(0, 26)};
  }
  ~DataRecord() {}

  void init(std::vector<char> shipmode) {
    randomize(shipmode);
  }

 private:
  void randomize(std::vector<char> _shipmode) {
    size_t rdn = _shipmode.size();
    std::random_device seed_gen;
    std::mt19937 engine(seed_gen());
    std::uniform_int_distribution<char> shipmode_message(0, rdn - 1);
    shipmode().set_value(_shipmode[shipmode_message(engine)]);
    std::uniform_int_distribution<Lvl1::T> orderpriority_message(0, 4);
    orderpriority().set_value(orderpriority_message(engine));

    commitdate().set_value(generate_date(20200101, 20221231));
    shipdate().set_value(generate_date(20200101, 20221231));
    receiptdate().set_value(generate_date(20200101, 20221231));
  }
};

class QueryRequest {
  using QDataL = QueryData<Lvl1::T>;
  using QDataC = std::vector<QueryData<char>>;
  using VariantType1 = std::variant<QDataL>;
  using VariantType2 = std::variant<QDataC>;

 public:
  std::array<VariantType1, 2> predicates;
  std::array<VariantType2, 1> groupby;
  QDataL& receiptdate1() { return std::get<QDataL>(predicates[0]); }
  QDataL& receiptdate2() { return std::get<QDataL>(predicates[1]); }
  QDataC& shipmode() { return std::get<QDataC>(groupby[0]); }

 public:
  QueryRequest() {
    predicates = {QDataL()};
    groupby = {QDataC()};
  }
  ~QueryRequest() {}

  void init(std::vector<char> _shipmode, int m) {
    randomize();
    generateGroup(_shipmode, m);
  }

 public:
  int pred_num() { return predicates.size(); }

 private:
  void randomize() {
    auto date = generate_date(20200101, 20221231);
    receiptdate1().value = date;
    receiptdate2().value = data_add(date, 1 * 10000); // + 1year
  }

  void generateGroup(std::vector<char> _shipmode, int m) {
    if (m > _shipmode.size()) {
      std::cerr << "Error: m is larger than the size of shipmode" << std::endl;
      exit(1);
    }
    shipmode().resize(m);
    for (size_t i = 0; i < m; i++) shipmode()[i].value = _shipmode[i];
  }
};

