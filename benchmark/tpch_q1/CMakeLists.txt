add_executable(tpch_q1 tpch_q1.cu)
target_include_directories(tpch_q1 PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../thirdparty/phantom-fhe/include ../utils)
target_link_libraries(tpch_q1 opera cutfhe++ OpenMP::OpenMP_CXX Phantom)
