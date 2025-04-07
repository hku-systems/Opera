add_executable(tpch_q12 tpch_q12.cu)
target_include_directories(tpch_q12 PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../thirdparty/phantom-fhe/include ../utils)
target_link_libraries(tpch_q12 opera cutfhe++ OpenMP::OpenMP_CXX Phantom)
