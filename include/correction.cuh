#pragma once

#include <cutfhe++.h>
#include "operator.cuh"

namespace opera
{
  template <typename Lvl = Lvl1, typename T = Lvl::T>
    void filter_correction(
        std::vector<PhantomCiphertext> &results,
        std::vector<std::vector<uint32_t>> &pred_res,
        PhantomRLWE &rlwe,
        std::vector<std::vector<CacheFilter>> &filters,
        /* group */
        std::vector<std::vector<CacheFilter>> &gfilters,
        double &correction_time,
        bool nocheck)
    {
      assert(gfilters.empty() ||
          (std::accumulate(gfilters.begin(), gfilters.end(), 1,
                           [](size_t product, const auto &vec) {
                           return product * vec.size();
                           }) == results.size()) &&
          "Invalid size");

      std::cout << "Start Correction.." << std::endl;
      std::vector<PhantomCiphertext> correct_filters;
      std::vector<std::vector<PhantomCiphertext>> correct_gfilters(results.size());
      auto start = std::chrono::high_resolution_clock::now();
      // correction, first predicates
      PhantomCiphertext res;
      bool res_init = false;
      for (size_t i = 0; i < filters.size(); ++i) {
        // check each filter, find ckks filter
        for (size_t j = 0; j < filters[i].size(); ++j) {
          auto &filter = filters[i][j];
          if (filter.is_ckks()) {
            if (filter.is_and()) {
              auto ckks_filter = filter.get_ckks_filter();
              correct_filters.push_back(ckks_filter);
              if (!res_init) {
                res = ckks_filter;
                res_init = true;
              } else {
                if (res.scale() > pow(2., 80))
                  rescale_to_next_inplace(*rlwe.context, res);
                multiply_and_relinearize(*rlwe.context, res, ckks_filter, res,
                    *rlwe.relin_keys);
              }
            } else
              assert("Not implemented.");
          }
        }
      }

      // gfilters
      if (gfilters.empty()) {
        /*assert(results.size() == 1);*/
        if (res_init) {
          multiply_and_relinearize(*rlwe.context, results[0], res, results[0], *rlwe.relin_keys);
          rescale_to_next_inplace(*rlwe.context, results[0]);
        }
      } else {
        size_t grp_num = results.size();
        std::vector<size_t> indices(gfilters.size(), 0);
        for (size_t i = 0; i < grp_num; i++) {
          PhantomCiphertext gres;
          bool gres_init = false;
          for (size_t j = 0; j < gfilters.size(); ++j) {
            auto gfilter = gfilters[j][indices[j]];
            if (gfilter.is_invalid()) continue;
            assert(gfilter.is_and() && "Not implemented.");
            if (gfilter.is_ckks()) {
              auto _filter = gfilter.get_ckks_filter();
              correct_gfilters[i].push_back(_filter);
              if (!gres_init) {
                gres = _filter;
                gres_init = true;
              } else
                multiply_and_relinearize(*rlwe.context, gres, _filter, gres, *rlwe.relin_keys);
            }
          }
          if (!gres_init) {
            if (res_init) {
              multiply_and_relinearize(*rlwe.context, res, results[i], results[i], *rlwe.relin_keys);
              rescale_to_next_inplace(*rlwe.context, results[i]);
            }
          } else {
            if (res_init) {
              multiply_and_relinearize(*rlwe.context, gres, res, gres, *rlwe.relin_keys);
            }
            multiply_and_relinearize(*rlwe.context, results[i], gres, results[i], *rlwe.relin_keys);
            rescale_to_next_inplace(*rlwe.context, results[i]);
          }
          // Move to next
          for (size_t k = gfilters.size(); k-- > 0;) {
            if (++indices[k] < gfilters[k].size()) {
              break;
            }
            indices[k] = 0;
          }
        }
      }

      auto end = std::chrono::high_resolution_clock::now();
      correction_time =
        std::chrono::duration_cast<std::chrono::milliseconds>(end - start)
        .count();
      std::cout << "[Correction] " << correction_time << "ms" << std::endl;

      if (!nocheck) {
        size_t groupby_num = pred_res.size();
        size_t slots_count = pred_res[0].size();
        std::vector<PhantomPlaintext> plain(groupby_num);
        std::vector<std::vector<double>> computed(groupby_num,
            std::vector<double>(slots_count));

        for (size_t i = 0; i < groupby_num; i++) {
          rlwe.secret_key->decrypt(*rlwe.context, results[i], plain[i]);
          pack_decode(*rlwe.context, computed[i], plain[i], *rlwe.ckks_encoder);
        }

        std::vector<double> err(groupby_num, 0.);
        for (size_t i = 0; i < groupby_num; i++) {
          for (size_t j = 0; j < slots_count; ++j) {
            err[i] += std::abs(computed[i][j] - pred_res[i][j]);
          }

          printf("Correction average error in %02ld = %f ~ 2^%.1f\n", i,
              err[i] / slots_count, std::log2(err[i] / slots_count));
        }
      }
    }

  template <typename Lvl = Lvl1, typename T = Lvl::T>
    void filter_correction(
        std::vector<PhantomCiphertext> &results,
        std::vector<std::vector<uint32_t>> &pred_res,
        PhantomRLWE &rlwe,
        std::vector<std::vector<CacheFilter>> &filters,
        /* group */
        std::vector<std::vector<CacheFilter>> &gfilters,
        double &correction_time)
    {
      filter_correction<Lvl, T>(results, pred_res, rlwe, filters, gfilters, correction_time, true);
    }

  inline bool tfhe_correction(
      CacheFilter &filter,
      TLWELvl1 *results,
      size_t batch_size,
      bool op = false)
  {
    bool _op = false;
    // hit!
    if (filter.is_tfhe()) {
      HomCOPY<Lvl1><<<GRID_DIM, BLOCK_DIM>>>(results, filter.get_d_tfhe_filter(), batch_size);
      _op = true;
    }
    return op || _op;
  }

  inline bool tfhe_correction(
      const Context &context,
      std::vector<CacheFilter> &filters,
      util::Pointer<BootstrappingData<Lvl01>> &bs_data,
      TLWELvl1 *results,
      size_t batch_size,
      bool op = false)
  {
    bool _op = false;
    if (filters.size() == 1) {
      tfhe_correction(filters[0], results, batch_size, _op);
      return op || _op;
    }
    for (size_t j = 0; j < filters.size(); j++) {
      auto &filter = filters[j];
      if (filter.is_tfhe()) {
        if (filter.is_or()) {
          HomOR<Lvl1,LOGIC>(context, bs_data, results, results, filter.get_d_tfhe_filter(), batch_size);
          _op = true;
        }
        if (filter.is_and()) {
          HomAND<Lvl1,LOGIC>(context, bs_data, results, results, filter.get_d_tfhe_filter(), batch_size);
          _op = true;
        }
      }
    }
    return op || _op;
  }

    inline bool tfhe_correction(
        const Context &context,
        std::vector<CacheFilter> &filters,
        util::Pointer<BootstrappingData<Lvl01>> &bs_data,
        util::Pointer<cuTLWE<Lvl1>> *tlwe,
        TLWELvl1 *results,
        size_t batch_size,
        double &accumulated_time)
    {
      TLWELvl1 *pt_tlwe = tlwe[0]->template get<Lvl1>();
      CUDA_CHECK_RETURN(cudaMemcpy(pt_tlwe, results, sizeof(TLWELvl1) * batch_size, cudaMemcpyHostToDevice));

      cudaEvent_t start, stop;
      RECORD_TIME_START(start, stop);

      bool op = tfhe_correction(context, filters, bs_data, pt_tlwe, batch_size);

      accumulated_time += RECORD_TIME_END(start, stop);

      CUDA_CHECK_RETURN(cudaMemcpy(results, pt_tlwe, sizeof(TLWELvl1) * batch_size, cudaMemcpyDeviceToHost));

      return op;
    }

    inline bool tfhe_correction(
        CacheFilter &filter,
        util::Pointer<cuTLWE<Lvl1>> *tlwe,
        TLWELvl1 *results,
        size_t batch_size,
        double &accumulated_time)
    {
      TLWELvl1 *pt_tlwe = tlwe[0]->template get<Lvl1>();
      CUDA_CHECK_RETURN(cudaMemcpy(pt_tlwe, results, sizeof(TLWELvl1) * batch_size, cudaMemcpyHostToDevice));

      cudaEvent_t start, stop;
      RECORD_TIME_START(start, stop);

      bool op = tfhe_correction(filter, pt_tlwe, batch_size);

      accumulated_time += RECORD_TIME_END(start, stop);

      CUDA_CHECK_RETURN(cudaMemcpy(results, pt_tlwe, sizeof(TLWELvl1) * batch_size, cudaMemcpyDeviceToHost));

      return op;
    }
}
