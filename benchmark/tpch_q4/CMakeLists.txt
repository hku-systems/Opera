add_executable(tpch_q4 tpch_q4.cu)
target_include_directories(tpch_q4 PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../thirdparty/phantom-fhe/include ../utils)
target_link_libraries(tpch_q4 opera cutfhe++ OpenMP::OpenMP_CXX Phantom)
