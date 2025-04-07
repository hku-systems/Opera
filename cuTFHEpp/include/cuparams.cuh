#pragma once

#include <cstdint>

namespace cuTFHEpp
{
    constexpr uint32_t DEVICE_ID = 0;

    constexpr dim3 GRID_DIM = dim3(1024, 1, 1);
    constexpr dim3 BLOCK_DIM = dim3(1024, 1, 1);

    template<typename P>
      constexpr uint32_t SHM_SIZE = P::n * sizeof(double);
} // namespace cuTFHEpp
