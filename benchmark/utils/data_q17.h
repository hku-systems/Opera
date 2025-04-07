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

  ValueL& extendedprice() { return std::get<ValueL>(values[0]); }
  ValueL& brand() { return std::get<ValueL>(values[1]); }
  ValueL& container() { return std::get<ValueL>(values[2]); }
  ValueL& quantity() { return std::get<ValueL>(values[3]); }
  ValueL& avg_quantity() { return std::get<ValueL>(values[4]); }

  DataRecord() {
    values = {ValueL(0, 10),  ValueL(0, 20), ValueL(0, 32),
              ValueL(0, 20),  ValueL(0, 20)};
  }
  ~DataRecord() {}

  void init() {
    randomize();
  }

 private:
  void randomize() {
    std::random_device seed_gen;
    std::mt19937 engine(seed_gen());
    std::uniform_int_distribution<Lvl1::T> extendedprice_message(1, 100);
    std::uniform_int_distribution<Lvl1::T> brand_message(0, 100);
    std::uniform_int_distribution<Lvl1::T> container_message(0, 100);
    std::uniform_int_distribution<Lvl1::T> quantity_message(0, 10000);
    std::uniform_int_distribution<Lvl1::T> avg_quantity_message(0, 10000);
    extendedprice().set_value(extendedprice_message(engine));
    brand().set_value(brand_message(engine));
    container().set_value(container_message(engine));
    quantity().set_value(quantity_message(engine));
    avg_quantity().set_value(avg_quantity_message(engine));  
  }
};

class QueryRequest {
  using QDataL = QueryData<Lvl1::T>;
  using QDataVL = std::vector<QueryData<Lvl1::T>>;
  using VariantType1 = std::variant<QDataL>;
  using VariantType2 = std::variant<QDataVL>;

 public:
  std::array<VariantType1, 2> predicates;
  QDataL& brand() { return std::get<QDataL>(predicates[0]); }
  QDataL& container() { return std::get<QDataL>(predicates[0]); }

 public:
  QueryRequest() {
    predicates = {QDataL(), QDataL()};
  }
  ~QueryRequest() {}

  void init() {
    randomize();
    generateGroupBy();
  }

 public:
  int pred_num() { return predicates.size(); }

 private:
  void randomize() {
    std::random_device seed_gen;
    std::mt19937 engine(seed_gen());
    std::uniform_int_distribution<Lvl1::T> brand_message(1, 100);
    std::uniform_int_distribution<Lvl1::T> container_message(1, 100);
    brand().value = brand_message(engine);
    container().value = container_message(engine);
  }

  void generateGroupBy() { }
};

