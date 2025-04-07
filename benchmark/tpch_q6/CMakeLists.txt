add_executable(tpch_q6 tpch_q6.cu)
target_include_directories(tpch_q6 PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../thirdparty/phantom-fhe/include ${CMAKE_CURRENT_SOURCE_DIR}/../utils ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(tpch_q6 opera cutfhe++ OpenMP::OpenMP_CXX Phantom)
