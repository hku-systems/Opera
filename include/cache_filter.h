#pragma once
#include "tlwe.h"

#define DENSITY_LIMIT (size_t)32
#define MAX_JUDGE (size_t) std::numeric_limits<T>::max()
#define EPSILON 1e-6

#define FASTCOMP

namespace opera
{
  using LWECiphertext = std::vector<TLWELvl1>;

  enum class CompLogic {
    INV = 0x0,
    NE = 0x1,
    EQ = 0x2,
    GT = 0x4,
    LT = 0x8,
    GE = GT | EQ,
    LE = LT | EQ,
    MASK = GT | LT | NE,
  };
  enum class FilterType {
    INV = 0x0,
    CKKS = 0x1,
    TFHE = 0x2,
  };
  enum class FilterLogic {
    INV = 0x0,
    AND = 0x1,
    OR = 0x2,
    NOT = 0x4,
    NAND = NOT | AND,
    NOR = NOT | OR,
  };

  inline size_t consume(size_t _density) {
    if (_density < 5)
      return 2;
    else if (_density < 9)
      return 5;
    else if (_density < 14)
      return 12;
    else if (_density < 19)
      return 19;
    else if (_density < 24)
      return 26;
    else if (_density < 29)
      return 33;
    else
      return 40;
  }

  template <typename T>
    class CacheMetadata {
      public:
        /* 32 means max density */
        CacheMetadata() : CacheMetadata(CompLogic::INV, 0) {}
        CacheMetadata(CompLogic compare_logic, T judge)
          : CacheMetadata(compare_logic, judge, MAX_JUDGE) {}
        CacheMetadata(CompLogic compare_logic, T judge, size_t next_judge)
          : compare_logic(compare_logic),
          judge(judge),
          next_judge(next_judge),
          lru(0),
          access(1),
          hit(0),
          D_ori(consume(DENSITY_LIMIT)),
          MULT(2) {
            /* D_ori - MULT */
            hit_model = D_ori - MULT;
            /* each iter needs 7ms */
            density_model = consume(get_density());
          }
        ~CacheMetadata() {}

        bool operator<(const CacheMetadata<T> &other) const {
          return judge < other.judge;
        }

        bool operator==(const CacheMetadata<T> &other) const {
          return judge == other.judge;
        }

        CompLogic get_logic() const { return compare_logic; }
        uint8_t get_mask_logic() const {
          return (uint8_t)compare_logic & (uint8_t)CompLogic::MASK;
        }
        T get_judge() const { return judge; }
        T get_next_judge() const { return next_judge; }
        size_t get_density() const {
          assert((next_judge >= judge) && "Invalid judge");
          auto diff = next_judge - judge + 1;
          return min((size_t)ceil(std::log2(diff)), DENSITY_LIMIT);
        }

        bool is_invalid() const { return compare_logic == CompLogic::INV; }

        void update_logic(CompLogic c) { compare_logic = c; }
        void update_judge(T j) { judge = j; }
        void update_density(T d) {
          assert((d > judge) || (d == 0 && judge == 0) && "Invalid judge");
          next_judge = d;
          density_model = consume(get_density());
        }
        void max_density() { next_judge = MAX_JUDGE; }
        void min_density() { next_judge = judge; }

        uint32_t get_access() const { return access; }
        uint32_t get_area_access() const { return access - hit; }
        uint32_t get_hit() const { return hit; }
        uint32_t get_lru() const { return lru; }

        void update_access() { access++; }
        void update_hit() {
          hit++;
          update_access();
        }
        void update_lru(uint32_t _lru) { lru = _lru; }

        void update_access(uint32_t _access) {
          assert(_access != 0 && _access >= hit && "Invalid access");
          access = _access;
        }
        void update_area_access(uint32_t _access) {
          access = hit + _access;
        }
        void update_hit(uint32_t _hit) { hit = _hit; }

        uint32_t get_density_model() const { return density_model; }
        uint32_t get_hit_model() const { return hit_model; }
        uint32_t get_D_ori() const { return D_ori; }

        double density_benefit(uint32_t count) const {
          return density_model * (access * 1.0 / count);
        }
        double hit_benefit(uint32_t count) const {
          return hit_model * (hit * 1.0 / count);
        }

        double loss_benefit(const CacheMetadata &_prev, uint32_t _count) {
          assert(_prev.get_next_judge() == judge && "Invalid judge");
          size_t u_i1 = _prev.get_access();
          size_t u_i = access;
          // d_{i-1} + d_i
          assert(next_judge >= _prev.get_judge());
          size_t d_i1i = next_judge - _prev.get_judge();
          size_t de_i1i = min((size_t)ceil(std::log2(d_i1i + 1)), DENSITY_LIMIT);
          size_t D_i1 = _prev.get_density_model();
          size_t D_i1i = consume(de_i1i);

          double _loss = ((u_i1 + u_i) * D_i1i * 1.0 / _count) -
            (_prev.density_benefit(_count) + density_benefit(_count)) +
            hit_benefit(_count);
          assert(_loss > 0 || abs(_loss) < EPSILON && "Invalid benefit");
          assert(isnan(_loss) == 0 && "Invalid loss");
          return abs(_loss) < EPSILON ? 0 : _loss;
        }

      private:
        CompLogic compare_logic;
        T judge;
        T next_judge;

        // lru used
        uint32_t lru;
        // dbe used
        uint32_t access;
        uint32_t hit;
        uint32_t density_model;
        uint32_t hit_model;

        uint32_t D_ori;
        uint32_t MULT;
    };

  class CacheFilter {
    public:
     CacheFilter()
         : filter_type(FilterType::INV), filter_logic(FilterLogic::INV) {}
     CacheFilter(PhantomCiphertext &c_filter, FilterLogic logic)
         : ckks_filter(c_filter),
           filter_type(FilterType::CKKS),
           filter_logic(logic) {}
     CacheFilter(std::vector<TLWELvl1> &t_filter, FilterLogic logic)
         : tfhe_filter(t_filter),
           filter_type(FilterType::TFHE),
           filter_logic(logic) {
       CUDA_CHECK_RETURN(
           cudaMalloc(&d_tfhe_filter, sizeof(TLWELvl1) * tfhe_filter.size()));
       CUDA_CHECK_RETURN(cudaMemcpy(d_tfhe_filter, tfhe_filter.data(),
                                    sizeof(TLWELvl1) * tfhe_filter.size(),
                                    cudaMemcpyHostToDevice));
     }

     CacheFilter(const CacheFilter &other)
         : ckks_filter(other.ckks_filter),
           tfhe_filter(other.tfhe_filter),
           filter_type(other.filter_type),
           filter_logic(other.filter_logic) {
       if (is_tfhe()) {
         CUDA_CHECK_RETURN(
             cudaMalloc(&d_tfhe_filter, sizeof(TLWELvl1) * tfhe_filter.size()));
         CUDA_CHECK_RETURN(
             cudaMemcpy(d_tfhe_filter, other.d_tfhe_filter,
                        sizeof(TLWELvl1) * other.tfhe_filter.size(),
                        cudaMemcpyDeviceToDevice));
       }
     }

     ~CacheFilter() {
       if (is_tfhe()) {
         CUDA_CHECK_RETURN(cudaFree(d_tfhe_filter));
       }
     }

      // assign operator
      CacheFilter &operator=(const CacheFilter &other) {
        if (this == &other) return *this;
        /* previous one */
        if (is_tfhe()) {
          CUDA_CHECK_RETURN(cudaFree(d_tfhe_filter));
        }
        ckks_filter = other.ckks_filter;
        tfhe_filter = other.tfhe_filter;
        filter_type = other.filter_type;
        filter_logic = other.filter_logic;
        if (is_tfhe()) {
          CUDA_CHECK_RETURN(cudaMalloc(&d_tfhe_filter,
                                       sizeof(TLWELvl1) * tfhe_filter.size()));
          CUDA_CHECK_RETURN(cudaMemcpy(d_tfhe_filter, other.d_tfhe_filter,
                                       sizeof(TLWELvl1) * tfhe_filter.size(),
                                       cudaMemcpyDeviceToDevice));
        }
        return *this;
      }

      void set_ckks_filter(PhantomCiphertext filter, FilterLogic logic) {
        ckks_filter = filter;
        filter_type = FilterType::CKKS;
        filter_logic = logic;
      }

      void set_tfhe_filter(std::vector<TLWELvl1> filter, FilterLogic logic) {
        tfhe_filter = filter;
        filter_type = FilterType::TFHE;
        filter_logic = logic;
      }

      PhantomCiphertext get_ckks_filter() const {
        assert(is_ckks() && "Invalid filter type");
        return ckks_filter;
      }

      TLWELvl1 get_tfhe_filter(size_t i) const {
        assert(is_tfhe() && "Invalid filter type");
        return tfhe_filter[i];
      }

      TLWELvl1* get_d_tfhe_filter() const {
        assert(is_tfhe() && "Invalid filter type");
        return d_tfhe_filter;
      }

      bool is_invalid() const { return filter_type == FilterType::INV; }
      bool is_ckks() const { return filter_type == FilterType::CKKS; }
      bool is_tfhe() const { return filter_type == FilterType::TFHE; }

      bool is_and() const {
        return (uint8_t)filter_logic & (uint8_t)FilterLogic::AND;
      }
      bool is_or() const {
        return (uint8_t)filter_logic & (uint8_t)FilterLogic::OR;
      }
      bool is_not() const {
        return (uint8_t)filter_logic & (uint8_t)FilterLogic::NOT;
      }

    private:
      PhantomCiphertext ckks_filter;
      std::vector<TLWELvl1> tfhe_filter;
      TLWELvl1 *d_tfhe_filter;
      FilterType filter_type;
      FilterLogic filter_logic;
  };

  template <typename Lvl, typename T = Lvl::T>
    class CacheManager {
      static_assert(std::is_same<Lvl, Lvl1>::value ||
          std::is_same<Lvl, Lvl2>::value,
          "Invalid Lvl");

      public:
      size_t min_density = 4;

      CacheManager(TFHESecretKey *p_sk, TFHEEvalKey *p_ek, PhantomRLWE *p_rlwe, size_t cap, bool fast_comp, bool dbe)
        : p_sk(p_sk), p_ek(p_ek), p_rlwe(p_rlwe), cap(cap), fast_comp(fast_comp), dbe(dbe) {}

      CacheManager(TFHESecretKey *p_sk, TFHEEvalKey *p_ek, PhantomRLWE *p_rlwe, bool fast_comp)
        : CacheManager(p_sk, p_ek, p_rlwe, 10, fast_comp, false) {}

      CacheManager(TFHESecretKey *p_sk, TFHEEvalKey *p_ek, PhantomRLWE *p_rlwe)
        : CacheManager(p_sk, p_ek, p_rlwe, 10, true, false) {}

      ~CacheManager() {}

      /* only generate a filter */
      void generate(const std::string _table, const std::vector<T> &_value,
          CompLogic _logic, T _judge) {
        std::cout << "Cache Filter Generate... " << "in table " << _table
          << std::endl;
        std::vector<uint32_t> vec;
        for (size_t i = 0; i < _value.size(); i++) {
          switch (_logic) {
            case CompLogic::GT:
              vec.push_back(!!(_value[i] > _judge));
              break;
            case CompLogic::LT:
              vec.push_back(!!(_value[i] < _judge));
              break;
            case CompLogic::GE:
              vec.push_back(!!(_value[i] >= _judge));
              break;
            case CompLogic::LE:
              vec.push_back(!!(_value[i] <= _judge));
              break;
            case CompLogic::NE:
              vec.push_back(!!(_value[i] != _judge));
              break;
            case CompLogic::EQ:
              vec.push_back(!!(_value[i] == _judge));
              break;
            default:
              assert(false && "Invalid compare logic");
              break;
          }
        }

        double scale = p_rlwe->scale;
        // ckks
        PhantomPlaintext plain;
        PhantomCiphertext cipher_ckks;
        LWECiphertext cipher_t;
#ifndef DBE_DEBUG
        pack_encode(*(p_rlwe->context), vec, scale, plain, *(p_rlwe->ckks_encoder));
        p_rlwe->secret_key->encrypt_symmetric(*(p_rlwe->context), plain, cipher_ckks, false);
        // tfhe
        for (size_t i = 0; i < _value.size(); i++) {
          TLWELvl1 cipher;
          cipher = TFHEpp::tlweSymEncrypt<Lvl1>(
            vec[i] ? Lvl1::μ : -Lvl1::μ, Lvl1::α, p_sk->key.get<Lvl1>());
          cipher_t.push_back(cipher);
        }
#endif
        CacheMetadata<T> metadata(_logic, _judge);
        insert(_table, cipher_ckks, cipher_t, metadata);
      }

      void generate(const std::string _table, const std::vector<T> &_value,
          CacheMetadata<T> _metadata) {
        std::cout << "Cache Filter Generate... " << "in table " << _table
          << std::endl;
        auto judge = _metadata.get_judge();
        auto compare_logic = _metadata.get_logic();

        // not equal & equal
        if (compare_logic == CompLogic::NE || compare_logic == CompLogic::EQ) {
          generate(_table, _value, compare_logic, judge);
          return;
        }

        // other, GT, LT, GE, LE
        size_t diff = 1 << (min_density - 1);
        // generate filters
        // 1. lower bound
        auto lower_bound = judge > diff ? judge - diff : 0;
        std::vector<uint32_t> lower_bound_vec;
        // 2. upper bound
        auto upper_bound = judge + diff > judge ? judge + diff : MAX_JUDGE;
        std::vector<uint32_t> upper_bound_vec;

        for (size_t i = 0; i < _value.size(); i++) {
          switch (compare_logic) {
            case CompLogic::GT:
              lower_bound_vec.push_back(!!(_value[i] > lower_bound));
              upper_bound_vec.push_back(!!(_value[i] > upper_bound));
              break;
            case CompLogic::LT:
              lower_bound_vec.push_back(!!(_value[i] < lower_bound));
              upper_bound_vec.push_back(!!(_value[i] < upper_bound));
              break;
            case CompLogic::GE:
              lower_bound_vec.push_back(!!(_value[i] >= lower_bound));
              upper_bound_vec.push_back(!!(_value[i] >= upper_bound));
              break;
            case CompLogic::LE:
              lower_bound_vec.push_back(!!(_value[i] <= lower_bound));
              upper_bound_vec.push_back(!!(_value[i] <= upper_bound));
              break;
            default:
              assert(false && "Invalid compare logic");
              break;
          }
        }

        // ckks
        double scale = p_rlwe->scale;
        // tfhe
        double pscale = pow(2., std::numeric_limits<Lvl1::T>::digits - 2);
        TLWELvl1 zero_cipher = TFHEpp::tlweSymInt32Encrypt<Lvl1>(
            0, Lvl1::α, pscale, p_sk->key.get<Lvl1>());

        // GT, LT, GE, LE
        if (lower_bound_vec.size() > 0) {
          PhantomPlaintext lower_bound_plain, upper_bound_plain;
          PhantomCiphertext lower_bound_cipher, upper_bound_cipher;
          LWECiphertext lower_bound_cipher_t, upper_bound_cipher_t;
#ifndef DBE_DEBUG
          // ckks
          pack_encode(*(p_rlwe->context), lower_bound_vec, scale, lower_bound_plain,
              *(p_rlwe->ckks_encoder));
          p_rlwe->secret_key->encrypt_symmetric(*(p_rlwe->context), lower_bound_plain, lower_bound_cipher, false);
          pack_encode(*(p_rlwe->context), upper_bound_vec, scale, upper_bound_plain,
              *(p_rlwe->ckks_encoder));
          p_rlwe->secret_key->encrypt_symmetric(*(p_rlwe->context), upper_bound_plain, upper_bound_cipher, false);
          // tfhe
          for (size_t i = 0; i < _value.size(); i++) {
            // Why we need use less_than instead of encrypt directly?
            TLWELvl1 lower_cipher, upper_cipher;

            lower_cipher = TFHEpp::tlweSymEncrypt<Lvl1>(
              lower_bound_vec[i] ? Lvl1::μ : -Lvl1::μ, Lvl1::α,
              p_sk->key.get<Lvl1>());
            lower_bound_cipher_t.push_back(lower_cipher);

            upper_cipher = TFHEpp::tlweSymEncrypt<Lvl1>(
              upper_bound_vec[i] ? Lvl1::μ : -Lvl1::μ, Lvl1::α,
              p_sk->key.get<Lvl1>());

            upper_bound_cipher_t.push_back(upper_cipher);
          }
#endif
          CacheMetadata<T> lower_meta(_metadata.get_logic(), lower_bound);
          insert(_table, lower_bound_cipher, lower_bound_cipher_t, lower_meta);
          CacheMetadata<T> upper_meta(_metadata.get_logic(), upper_bound);
          insert(_table, upper_bound_cipher, upper_bound_cipher_t, upper_meta);
        }
      }

      void find(const std::string &_table, std::vector<T> &_value, CompLogic _logic,
          T _judge) {
        std::vector<CacheFilter> filters;
        CacheMetadata<T> metadata(_logic, _judge);
        find(_table, filters, metadata);
      }

      void find(const std::string &_table, std::vector<CacheFilter> &_filters,
          CacheMetadata<T> &_metadata) {
        // non-exist table
        if (metadata.find(_table) == metadata.end()) {
          _filters.clear();
          _metadata.max_density();
          return;
        }

        auto judge = _metadata.get_judge();
        auto compare_logic = _metadata.get_logic();
        auto ne_eq =
          compare_logic == CompLogic::NE || compare_logic == CompLogic::EQ;
        // find nearest filters
        auto &meta_vec = metadata[_table];
        auto hit = std::find(meta_vec.begin(), meta_vec.end(), _metadata);
        if (hit != meta_vec.end()) {
          size_t index = std::distance(meta_vec.begin(), hit);
          // _metadata exsits, hit!
          if (hit->get_logic() == _metadata.get_logic()) {
            _filters.resize(1);
            _filters[0] = fast_comp ?
                CacheFilter(ckks_cache[_table][index], FilterLogic::AND) :
                CacheFilter(tfhe_cache[_table][index], FilterLogic::AND);
            _metadata.min_density();
            // update access and hit
            hit->update_lru(count[_table]++);
            hit->update_hit();
            return;
          }
          assert(false && "Not implemented yet");
          return;
        }
        // ne and eq will not go through this
        if (ne_eq) {
          _filters.clear();
          _metadata.max_density();
          return;
        }

        auto cacheIter =
          std::upper_bound(meta_vec.begin(), meta_vec.end(), _metadata);
        auto index = std::distance(meta_vec.begin(), cacheIter);
        if (index == 0 || index == meta_vec.size()) {
          // not found
          _filters.clear();
          _metadata.max_density();
          // update find access
          if (index != 0) meta_vec[index - 1].update_access();
          return;
        }
        auto &prev = meta_vec[index - 1];
        auto &next = meta_vec[index];
        assert(prev.get_judge() < next.get_judge() &&
            prev.get_judge() < next.get_judge() && "Invalid judge");
        _filters.resize(2);
        assert(metadata[_table][index - 1].get_judge() <
            metadata[_table][index].get_judge());
        if (prev.get_mask_logic() == _metadata.get_mask_logic()) {
          if (_metadata.get_mask_logic() == (uint8_t)CompLogic::GT) {
            // prev is the same logic (red zone)
            _filters[0] = fast_comp ?
                CacheFilter(ckks_cache[_table][index - 1], FilterLogic::AND) :
                CacheFilter(tfhe_cache[_table][index - 1], FilterLogic::AND);
          } else {
            // green zone
            _filters[0] =
              CacheFilter(tfhe_cache[_table][index - 1], FilterLogic::OR);
          }
        } else
          assert(false && "Not implemented yet");
        if (next.get_mask_logic() == _metadata.get_mask_logic()) {
          if (_metadata.get_mask_logic() == (uint8_t)CompLogic::GT) {
            // next is the same logic (green zone)
            _filters[1] = CacheFilter(tfhe_cache[_table][index], FilterLogic::OR);
          } else {
            _filters[1] = fast_comp ?
                CacheFilter(ckks_cache[_table][index], FilterLogic::AND) :
                CacheFilter(tfhe_cache[_table][index], FilterLogic::AND);
          }
        } else
          assert(false && "Not implemented yet");
        // return density
        auto diff = max(next.get_judge() - _metadata.get_judge(),
            _metadata.get_judge() - prev.get_judge());
        _metadata.update_density(_metadata.get_judge() + diff);
        // update access
        prev.update_lru(count[_table]++);
        next.update_lru(count[_table]++);
        prev.update_access();
        next.update_access();
        std::cout << _table << " visit: " << index - 1 << " " << index << std::endl;
      }

      void clear() {
        ckks_cache.clear();
        tfhe_cache.clear();
        metadata.clear();
        capacity.clear();
        count.clear();
      }

      private:
      std::unordered_map<std::string, std::vector<PhantomCiphertext>> ckks_cache;
      std::unordered_map<std::string, std::vector<LWECiphertext>> tfhe_cache;
      std::unordered_map<std::string, std::vector<CacheMetadata<T>>> metadata;
      TFHESecretKey *p_sk;
      TFHEEvalKey *p_ek;
      PhantomRLWE *p_rlwe;

      bool fast_comp;
      bool dbe;
      size_t cap;
      std::unordered_map<std::string, size_t> capacity;
      std::unordered_map<std::string, uint32_t> count;

      bool eviction_lru(const std::string &_key, ptrdiff_t &_index,
          CacheMetadata<T> &_metadata) {
        auto &meta_vec = metadata[_key];
        if (meta_vec.empty()) return false;
        auto last_lru = meta_vec[0].get_lru();
        auto last_meta = 0;
        for (int i = 1; i < meta_vec.size(); i++) {
          if (meta_vec[i].get_lru() < last_lru) {
            last_lru = meta_vec[i].get_lru();
            last_meta = i;
          }
        }
        std::cout << "evict: " << last_meta << std::endl;
        meta_vec.erase(meta_vec.begin() + last_meta);
        ckks_cache[_key].erase(ckks_cache[_key].begin() + last_meta);
        tfhe_cache[_key].erase(tfhe_cache[_key].begin() + last_meta);
        // correct the index
        auto cacheIter =
          std::upper_bound(meta_vec.begin(), meta_vec.end(), _metadata);
        _index = std::distance(meta_vec.begin(), cacheIter);
        return true;
      }

      double insert_benefit(CacheMetadata<T> &_prev, CacheMetadata<T> &_curr,
          CacheMetadata<T> &_next, uint32_t &_count) {
        size_t d_i = _prev.get_next_judge() - _prev.get_judge();
        size_t D_i = _prev.get_density_model();
        size_t u_i = _prev.get_access();
        size_t a_i = _prev.get_hit();
        size_t d_i1 = _next.get_next_judge() - _next.get_judge();
        size_t u_i1 = _next.get_access();
        size_t a_i1 = _next.get_hit();
        size_t d_j = _curr.get_next_judge() - _curr.get_judge();
        assert(_prev.get_next_judge() == _next.get_judge() && "Invalid judge");
        assert(_curr.get_next_judge() == _next.get_judge() ||
            _next.is_invalid() && "Invalid judge");
        size_t D_j = _curr.get_density_model();
        // d_i - d_j
        size_t d_ij = _curr.get_judge() - _prev.get_judge();
        size_t de_ij = min((size_t)ceil(std::log2(d_ij + 1)), DENSITY_LIMIT);
        size_t D_ij = consume(de_ij);
        // d_i + d_i1
        size_t d_ii1 = _next.get_next_judge() - _prev.get_judge();
        // d_i1 + d_j
        size_t d_i1j = _next.get_next_judge() - _curr.get_judge();

        // avoid divide by zero
        // for first is invalid
        d_i = max(d_i, (size_t)1);
        d_ij = max(d_ij, (size_t)1);
        // for last is invalid
        d_i1 = max(d_i1, (size_t)1);
        d_ii1 = max(d_ii1, (size_t)1);
        d_i1j = max(d_i1j, (size_t)1);

        // TODO, when density is infinite...
        size_t u_i_a = _prev.get_area_access();
        size_t u_i1_a = _next.get_area_access();
        double hat_a_j = (a_i + a_i1) * 0.5;
        double hat_u_j = 0.;
        size_t u_ii1 = u_i_a + u_i1_a;
        if (u_ii1 > u_i_a * pow(1 + d_i1 * 1.0 / d_i, 2) ||
            u_ii1 > u_i1_a * pow(1 + d_i * 1.0 / d_i1, 2)) {
          // 1. if abs(u_i_a - u_i1_a) is too large
          hat_u_j = (u_i_a * 1.0 / d_i) * d_j;
        } else {
          // 2. others, use the formula in the paper
          hat_u_j = ((u_i1_a * 1.0 / d_i1) * d_ij + (u_i_a * 1.0 / d_i) * d_i1j) *
            (d_j * 1.0 / d_ii1);
        }
        // 3. if insert filter is in the first or last, give some bonus
        if (_prev.is_invalid()) {
          hat_u_j = max(hat_u_j, u_i1_a * 0.5);
        }
        if (_next.is_invalid()) {
          hat_u_j = min(hat_u_j, u_i_a * 0.5);
        }

        /* sum to get the access count */
        assert(isnan(hat_u_j) == 0 && "Invalid hat_u_j");
        _curr.update_hit((uint32_t)(hat_a_j));
        _curr.update_area_access(max((uint32_t)(hat_u_j), (uint32_t)1));

        hat_u_j = hat_u_j + hat_a_j;
        // update prev access data
        if (_prev.is_invalid()) {
          u_i = (uint32_t)(hat_u_j) + 1;
          a_i = (uint32_t)(hat_a_j);
          _prev.update_hit(a_i);
          _prev.update_access(u_i);
        }

        assert((_curr.get_area_access() <= _prev.get_area_access()) &&
            "Invalid access");

        double _benefit = (u_i * D_i - (hat_u_j * D_j + (u_i - hat_u_j) * D_ij) +
            hat_a_j * _curr.get_hit_model()) *
          1.0 / _count;
        _count += (uint32_t)(hat_u_j);
        assert(_benefit > 0 || abs(_benefit) < EPSILON && "Invalid benefit");
        assert(isnan(_benefit) == 0 && "Invalid benefit");
        return abs(_benefit) < EPSILON ? 0 : _benefit;
      }

      bool eviction_dbe(const std::string &_key, ptrdiff_t &_index,
          CacheMetadata<T> &_metadata) {
        auto &meta_vec = metadata[_key];
        auto &meta_count = count[_key];
        if (meta_vec.empty()) return false;
        auto next = _index < meta_vec.size()
          ? meta_vec[_index]
          : CacheMetadata<T>(CompLogic::INV, MAX_JUDGE);
        auto prev = _index >= 1
          ? meta_vec[_index - 1]
          : CacheMetadata<T>(CompLogic::INV, 0, next.get_judge());
        auto last_meta = 0;
        auto last_loss = meta_vec[0].loss_benefit(
            CacheMetadata<T>(CompLogic::INV, 0, meta_vec[0].get_judge()),
            meta_count);
        std::cout << "loss 0: " << last_loss << "(" << meta_vec[0].get_access()
          << ")(" << meta_vec[0].get_judge() << ")" << " ";
        for (int i = 1; i < meta_vec.size(); i++) {
          auto loss = meta_vec[i].loss_benefit(meta_vec[i - 1], meta_count);
          std::cout << "loss " << i << ": " << loss << "("
            << meta_vec[i].get_access() << ")(" << meta_vec[i].get_judge()
            << ")" << " ";
          if (loss < last_loss) {
            last_loss = loss;
            last_meta = i;
          }
        }
        std::cout << std::endl;
        // check if we need to evict
        double ibenefit = insert_benefit(prev, _metadata, next, meta_count);
        {
          std::cout << "ibenefit: " << ibenefit << " loss: " << last_loss
            << " count: " << meta_count << std::endl;
          std::cout << "insert: " << _metadata.get_judge() << std::endl;
        }
        if (ibenefit <= last_loss) return false;
        {
          std::cout << "== evict == " << last_meta << std::endl;
          std::cout << "prev: " << prev.get_judge() << " " << prev.get_density()
            << " " << prev.get_access() << " " << prev.get_hit()
            << std::endl;
          std::cout << "curr: " << _metadata.get_judge() << " "
            << _metadata.get_density() << " " << _metadata.get_access()
            << " " << _metadata.get_hit() << std::endl;
          std::cout << "next: " << next.get_judge() << " " << next.get_density()
            << " " << next.get_access() << " " << next.get_hit()
            << std::endl;
        }
        // correct the density
        if (last_meta != 0) {
          // not first, update the prev element
          size_t _density = 0;
          if (last_meta != meta_vec.size() - 1) {
            // not last
            _density = meta_vec[last_meta + 1].get_judge();
          } else {
            _density = MAX_JUDGE;
          }
          meta_vec[last_meta - 1].update_density(_density);
          // update access
          auto access = meta_vec[last_meta - 1].get_access() +
            meta_vec[last_meta].get_access();
          meta_vec[last_meta - 1].update_access(access);
        }

        meta_vec.erase(meta_vec.begin() + last_meta);
        ckks_cache[_key].erase(ckks_cache[_key].begin() + last_meta);
        tfhe_cache[_key].erase(tfhe_cache[_key].begin() + last_meta);
        // correct the index
        auto cacheIter =
          std::upper_bound(meta_vec.begin(), meta_vec.end(), _metadata);
        _index = std::distance(meta_vec.begin(), cacheIter);

        return true;
      }

      void insert(const std::string &_key, const PhantomCiphertext &_ckks,
          const LWECiphertext &_tfhe, const CacheMetadata<T> &_metadata) {
        CacheMetadata<T> curr_meta = _metadata;
        // update density & access
        curr_meta.update_lru(count[_key]++);
        curr_meta.max_density();
        assert(metadata.size() == capacity.size());
        if (metadata.find(_key) == metadata.end()) {
          ckks_cache[_key] = {_ckks};
          tfhe_cache[_key] = {_tfhe};
          metadata[_key] = {curr_meta};
          capacity[_key] = cap;
          return;
        }
        auto &meta_vec = metadata[_key];
        auto hit = std::find(meta_vec.begin(), meta_vec.end(), curr_meta);
        if (hit != meta_vec.end()) {
          // _metadata exsits
          hit->update_lru(count[_key]++);
          hit->update_access();
          return;
        }

        auto cacheIter =
          std::upper_bound(meta_vec.begin(), meta_vec.end(), curr_meta);
        auto index = std::distance(meta_vec.begin(), cacheIter);
        // update density of insert filter
        if (index < meta_vec.size()) {
          // not last
          auto next = meta_vec[index].get_judge();
          curr_meta.update_density(next);
        } else {
          curr_meta.max_density();
        }

        // evict
        auto current_size = metadata[_key].size();
        bool has_space = current_size < capacity[_key];
        if (!has_space) {
          has_space = dbe ? eviction_dbe(_key, index, curr_meta) :
            eviction_lru(_key, index, curr_meta);
        }

        // no evicted, insert is not allowed
        if (!has_space) return;

        // update again, if evicted
        if (index < meta_vec.size()) {
          // not last
          auto next = meta_vec[index].get_judge();
          curr_meta.update_density(next);
        } else {
          curr_meta.max_density();
        }

        if (index != 0) {
          // not first, update the prev element
          auto curr = curr_meta.get_judge();
          meta_vec[index - 1].update_density(curr);
          if (dbe) {
            // update access
            auto access = (int64_t)meta_vec[index - 1].get_area_access() -
              (int64_t)curr_meta.get_area_access();
            assert(access >= 0 && "Invalid access");
            meta_vec[index - 1].update_area_access(max(access, (int64_t)1));
          }
        }
        ckks_cache[_key].insert(ckks_cache[_key].begin() + index, _ckks);
        tfhe_cache[_key].insert(tfhe_cache[_key].begin() + index, _tfhe);
        meta_vec.insert(meta_vec.begin() + index, curr_meta);
      }
    };

}
