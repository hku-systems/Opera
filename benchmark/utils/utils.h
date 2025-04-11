#pragma once

#include <string>
#include <fstream>
#include "gate.cuh"
#include "argparse.hpp"

void add_arguments(argparse::ArgumentParser& program)
{
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
}

void output_result(std::string output, std::vector<std::vector<double>>& time, bool cache_enabled)
{
  std::string output_head = cache_enabled ?
    "rows,fhc,phc,lwe_correct,rlwe_correct,packing,aggregation,end2end" :
    "rows,filter,packing,aggregation,end2end";

  if (output.empty()) {
    std::cout << "--------------------------------" << std::endl;
    std::cout << output_head << std::endl;
    for (size_t i = 0; i < time.size(); i++) {
      for (size_t j = 0; j < time[i].size(); j++) {
        std::cout << time[i][j] << ",";
      }
      std::cout << std::endl;
    }
  }
  else {
    std::ofstream ofs(output);
    ofs << output_head << std::endl;
    for (size_t i = 0; i < time.size(); i++) {
      for (size_t j = 0; j < time[i].size(); j++) {
        ofs << time[i][j] << ",";
      }
      ofs << std::endl;
    }
  }
}

void record_e2e_time(std::vector<double>& time, size_t rows,
                double filter_time, double conversion_time, double aggregation_time)
{
  std::cout << "End-to-End Time: "
         << (filter_time + conversion_time + aggregation_time) / 1000 << " s"
         << std::endl;

    time.push_back(rows);
    time.push_back(filter_time/1000);
    time.push_back(conversion_time/1000);
    time.push_back(aggregation_time/1000);
    time.push_back((filter_time+conversion_time+aggregation_time)/1000);
}

void record_e2e_time_cache(std::vector<double>& time, size_t rows,
                double filter_time, double tfhe_correction_time, double conversion_time,
                double ckks_correction_time, double aggregation_time)
{
  std::cout << "End-to-End Time: "
       << (filter_time + tfhe_correction_time + conversion_time + ckks_correction_time + aggregation_time) / 1000 << " s"
       << std::endl;
  time.push_back(rows);
  time.push_back((filter_time+tfhe_correction_time+ckks_correction_time)/1000);
  time.push_back(filter_time/1000);
  time.push_back(tfhe_correction_time/1000);
  time.push_back(ckks_correction_time/1000);
  time.push_back(conversion_time/1000);
  time.push_back(aggregation_time/1000);
  time.push_back((filter_time+tfhe_correction_time+ckks_correction_time+conversion_time+aggregation_time)/1000);
}

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
