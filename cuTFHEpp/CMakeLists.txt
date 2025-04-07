cmake_minimum_required(VERSION 3.16)
project(cutfhe++ VERSION 1.0 LANGUAGES CUDA CXX)

# set(CMAKE_CUDA_FLAGS "-g -G -std=c++20 -maxrregcount=64 -arch=sm_80 -ccbin g++ -expt-relaxed-constexpr")
set(CMAKE_CUDA_FLAGS "-O2 -std=c++20 -maxrregcount=64 -arch=sm_80 -ccbin g++ -expt-relaxed-constexpr")

set(cutfhe++_sources "")
add_subdirectory(src)

# target_include_directories(cutfhe++ PUBLIC src)
target_link_libraries(cutfhe++ tfhe++)

add_subdirectory(test)
