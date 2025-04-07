add_executable(tpch_q15 tpch_q15.cu)
target_include_directories(tpch_q15 PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../thirdparty/phantom-fhe/include ../utils)
target_link_libraries(tpch_q15 opera cutfhe++ OpenMP::OpenMP_CXX Phantom)
