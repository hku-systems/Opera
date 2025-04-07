add_executable(tpch_q17 tpch_q17.cu)
target_include_directories(tpch_q17 PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../thirdparty/phantom-fhe/include ../utils)
target_link_libraries(tpch_q17 opera cutfhe++ OpenMP::OpenMP_CXX Phantom)
