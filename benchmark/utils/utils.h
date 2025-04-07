#pragma once

#include "gate.cuh"
#include "argparse.hpp"

uint64_t generate_date(uint64_t down, uint64_t up)
{
  uint64_t dyear, dmonth, dday, uyear, umonth, uday;
  dyear = down / 10000;
  dmonth = (down / 100) % 100;
  dday = down % 100;
  uyear = up / 10000;
  umonth = (up / 100) % 100;
  uday = up % 100;
  std::random_device seed_gen;
  std::default_random_engine engine(seed_gen());
  std::uniform_int_distribution<Lvl1::T> day_message(dday, uday);
  std::uniform_int_distribution<Lvl1::T> month_message(dmonth, umonth);
  std::uniform_int_distribution<Lvl1::T> year_message(dyear, uyear);
  return day_message(engine) + 100 * month_message(engine) + 10000 * year_message(engine);
}

uint32_t data_add(uint32_t a, uint32_t b) {
  uint64_t ayear, amonth, aday, byear, bmonth, bday;
  ayear = a / 10000;
  amonth = (a / 100) % 100;
  aday = a % 100;
  byear = b / 10000;
  bmonth = (b / 100) % 100;
  bday = b % 100;
  aday += bday;
  if (aday > 31) {
    aday -= 31;
    amonth++;
  }
  amonth += bmonth;
  if (amonth > 12) {
    amonth -= 12;
    ayear++;
  }
  ayear += byear;
  return aday + 100 * amonth + 10000 * ayear;
}

template <typename T>
class Value {
 public:
  T value;
  uint32_t bits;

 public:
  Value() : value(0), bits(0) {}
  Value(T v, uint32_t b) : value(v), bits(b) {}
  ~Value() {}
  void set(T v, uint32_t b) {
    value = v;
    bits = b;
  }
  void set_value(T v) { value = v; }
  void set_bits(uint32_t b) { bits = b; }

 public:
  template <typename Level>
  int scale_bits() {
    return std::numeric_limits<typename Level::T>::digits - bits - 1;
  }
};

template <typename T>
class QueryData {
 public:
  T value;
  uint32_t record_index;

 private:
  using ComparisonFunction = std::function<bool(const T&, const T&)>;
  ComparisonFunction compare;

 public:
  QueryData(T v) : value(v), record_index(0) {}
  QueryData() {
    if constexpr (std::is_same_v<decltype(value), int>) {
      value = 0;
    } else if constexpr (std::is_same_v<decltype(value), char>) {
      value = 0;
    } else if constexpr (std::is_same_v<decltype(value), Lvl1::T>) {
      value = 0;
    } else {
      static_assert(TFHEpp::false_v<T>, "Undefined type!");
    }
    record_index = 0;
  }
  ~QueryData() {}

  bool operator==(const T& other) const {
    return value == other;
  }

  void setComparisonFunction(ComparisonFunction compFunc) {
    compare = compFunc;
  }

  inline uint32_t getRecordIndex() { return record_index; }
  void setIndex(uint32_t index) { record_index = index; }

 public:
  bool compareValues(const T& otherValue) const {
    if (compare) {
      return compare(otherValue, value);
    }
    return false;
  }
};
