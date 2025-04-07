add_executable(comparison_test comparison.cu)
target_link_libraries(comparison_test opera cutfhe++ OpenMP::OpenMP_CXX)
