option(CUTFHEPP_BUILD_TESTS "Build the cuTFHEpp tests" OFF)

if(CUTFHEPP_BUILD_TESTS)
  message(STATUS "Building the cuTFHEpp tests")
  add_subdirectory(fft)
  add_subdirectory(keyswitch)
  add_subdirectory(gatebootstrapping)
endif()
