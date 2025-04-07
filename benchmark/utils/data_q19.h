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

  ValueL& brand() { return std::get<ValueL>(values[0]); }
  ValueL& container() { return std::get<ValueL>(values[1]); }
  ValueL& quantity() { return std::get<ValueL>(values[2]); }
  ValueL& size() { return std::get<ValueL>(values[3]); }
  ValueL& shipmode() { return std::get<ValueL>(values[4]); }
  ValueL& shipinstruct() { return std::get<ValueL>(values[5]); }
  ValueD& revenue() { return std::get<ValueD>(values[6]); }

  DataRecord() {
    values = {ValueL(0, 20),  ValueL(0, 32), ValueL(0, 20),
              ValueL(0, 20),  ValueL(0, 32),  ValueL(0, 32),
              ValueD(0, 20)};
  }
  ~DataRecord() {}

  void init(std::vector<Lvl1::T> container, std::vector<Lvl1::T> shipmode) {
    randomize(container, shipmode);
  }

 private:
  void randomize(std::vector<Lvl1::T> _container,
                 std::vector<Lvl1::T> _shipmode) {
    std::random_device seed_gen;
    std::mt19937 engine(seed_gen());
    std::uniform_int_distribution<Lvl1::T> brand_message(1, 50);
    std::uniform_int_distribution<Lvl1::T> container_message(0, _container.size() - 1);
    std::uniform_int_distribution<Lvl1::T> quantity_message(0, 100);
    std::uniform_int_distribution<Lvl1::T> size_message(0, 100);
    std::uniform_int_distribution<Lvl1::T> shipmode_message(0, _shipmode.size() - 1);
    std::uniform_int_distribution<Lvl1::T> shipinstruct_message(0, 1000);
    std::uniform_real_distribution<double> revenue_message(0, 10000);
    brand().set_value(brand_message(engine));
    container().set_value(_container[container_message(engine)]);
    quantity().set_value(quantity_message(engine));
    size().set_value(size_message(engine));
    shipmode().set_value(_shipmode[shipmode_message(engine)]);
    shipinstruct().set_value(shipinstruct_message(engine));
    revenue().set_value(revenue_message(engine));  
  }
};

class QueryRequest {
  using QDataL = QueryData<Lvl1::T>;
  using QDataVL = std::vector<QueryData<Lvl1::T>>;
  using VariantType1 = std::variant<QDataL>;
  using VariantType2 = std::variant<QDataVL>;

 public:
  std::array<VariantType1, 6 * 3> predicates;
  // QueryData<Lvl1::T> brand;
  // QueryData<Lvl1::T> quantity;
  // QueryData<Lvl1::T> size;
  // QueryData<Lvl1::T> shipinstruct;
  QDataL& brand1() { return std::get<QDataL>(predicates[0]); }
  QDataL& quantity1_low() { return std::get<QDataL>(predicates[1]); }
  QDataL& quantity1_high() { return std::get<QDataL>(predicates[2]); }
  QDataL& size1_low() { return std::get<QDataL>(predicates[3]); }
  QDataL& size1_high() { return std::get<QDataL>(predicates[4]); }
  QDataL& shipinstruct1() { return std::get<QDataL>(predicates[5]); }

  QDataL& brand2() { return std::get<QDataL>(predicates[6]); }
  QDataL& quantity2_low() { return std::get<QDataL>(predicates[7]); }
  QDataL& quantity2_high() { return std::get<QDataL>(predicates[8]); }
  QDataL& size2_low() { return std::get<QDataL>(predicates[9]); }
  QDataL& size2_high() { return std::get<QDataL>(predicates[10]); }
  QDataL& shipinstruct2() { return std::get<QDataL>(predicates[11]); }

  QDataL& brand3() { return std::get<QDataL>(predicates[12]); }
  QDataL& quantity3_low() { return std::get<QDataL>(predicates[13]); }
  QDataL& quantity3_high() { return std::get<QDataL>(predicates[14]); }
  QDataL& size3_low() { return std::get<QDataL>(predicates[15]); }
  QDataL& size3_high() { return std::get<QDataL>(predicates[16]); }
  QDataL& shipinstruct3() { return std::get<QDataL>(predicates[17]); }


  std::array<VariantType2, 2 * 3> groupby;
  // QueryData<Lvl1::T> container;
  // QueryData<Lvl1::T> shipmode;
  QDataVL& container1() { return std::get<QDataVL>(groupby[0]); }
  QDataVL& shipmode1() { return std::get<QDataVL>(groupby[1]); }

  QDataVL& container2() { return std::get<QDataVL>(groupby[2]); }
  QDataVL& shipmode2() { return std::get<QDataVL>(groupby[3]); }

  QDataVL& container3() { return std::get<QDataVL>(groupby[4]); }
  QDataVL& shipmode3() { return std::get<QDataVL>(groupby[5]); }

 public:
  QueryRequest() {
    predicates = {QDataL(), QDataL(), QDataL(), QDataL(), QDataL(), QDataL(),
                  QDataL(), QDataL(), QDataL(), QDataL(), QDataL(), QDataL(),
                  QDataL(), QDataL(), QDataL(), QDataL(), QDataL(), QDataL()};
    groupby = {QDataVL(), QDataVL(), QDataVL(),
               QDataVL(), QDataVL(), QDataVL()};
  }
  ~QueryRequest() {}

  void init(std::vector<Lvl1::T> container, int con_size,
            std::vector<Lvl1::T> shipmode, int ship_size) {
    randomize();
    generateGroupBy(container, con_size, shipmode, ship_size);
  }

 public:
  int pred_num() { return predicates.size(); }

 private:
  void randomize() { 
    std::random_device seed_gen;
    std::mt19937 engine(seed_gen());
    std::uniform_int_distribution<Lvl1::T> brand_message(1, 50);
    std::uniform_int_distribution<Lvl1::T> quantity_message(0, 100);
    std::uniform_int_distribution<Lvl1::T> size_message(0, 100);
    std::uniform_int_distribution<Lvl1::T> shipinstruct_message(0, 1000);
    brand1().value = brand_message(engine);
    quantity1_low().value = quantity_message(engine);
    quantity1_high().value = quantity1_low().value + 10;
    size1_low().value = size_message(engine);
    size1_high().value = size1_high().value + 5;
    shipinstruct1().value = shipinstruct_message(engine);

    brand2().value = brand_message(engine);
    quantity2_low().value = quantity_message(engine);
    quantity2_high().value = quantity2_low().value + 10;
    size2_low().value = size_message(engine);
    size2_high().value = size2_high().value + 5;
    shipinstruct2().value = shipinstruct_message(engine); 

    brand3().value = brand_message(engine);
    quantity3_low().value = quantity_message(engine);
    quantity3_high().value = quantity3_low().value + 10;
    size3_low().value = size_message(engine);
    size3_high().value = size3_high().value + 5;
    shipinstruct3().value = shipinstruct_message(engine); 
  }

  void generateGroupBy(std::vector<Lvl1::T> _container, int con_size,
                       std::vector<Lvl1::T> _shipmode, int ship_size) {
    for (int i = 0; i < con_size; i++) {
      container1().push_back(QDataL(_container[i]));
      container2().push_back(QDataL(_container[i]));
      container3().push_back(QDataL(_container[i]));
    }
    for (int i = 0; i < ship_size; i++) {
      shipmode1().push_back(QDataL(_shipmode[i]));
      shipmode2().push_back(QDataL(_shipmode[i]));
      shipmode3().push_back(QDataL(_shipmode[i]));
    }
  }
};
