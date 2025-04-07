cmake_minimum_required(VERSION 3.16)
set(CMAKE_CUDA_ARCHITECTURES 80)
project(opera VERSION 1.0 LANGUAGES CUDA CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/lib)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/lib)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/bin)
set(CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake")

find_package(OpenMP)
if(OpenMP_FOUND)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${OpenMP_CXX_FLAGS}")
endif()

set(PHANTOM_ENABLE_BENCH OFF CACHE BOOL "Disable phantom bench" FORCE)
set(PHANTOM_ENABLE_PYTHON_BINDING OFF CACHE BOOL "Disable phanotom python binding" FORCE)
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/phantom-fhe/include)

add_subdirectory(thirdparty/phantom-fhe)
add_subdirectory(thirdparty/TFHEpp)
add_subdirectory(cuTFHEpp)

# set(CMAKE_CUDA_FLAGS "-g -G -std=c++20 -maxrregcount=64 -arch=sm_80 -ccbin g++ -expt-relaxed-constexpr")
set(CMAKE_CUDA_FLAGS "-O2 -std=c++20 -arch=sm_80 -ccbin g++ -expt-relaxed-constexpr")

set(opera_sources "")
add_subdirectory(src)

target_link_libraries(opera cutfhe++ tfhe++ Phantom)

add_subdirectory(test)
add_subdirectory(benchmark)
