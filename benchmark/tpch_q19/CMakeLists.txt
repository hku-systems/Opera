add_executable(tpch_q19 tpch_q19.cu)
target_include_directories(tpch_q19 PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../thirdparty/phantom-fhe/include ../utils)
target_link_libraries(tpch_q19 opera cutfhe++ OpenMP::OpenMP_CXX Phantom)
