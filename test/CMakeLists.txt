option(OPERA_BUILD_TESTS "Build the OPERA tests" OFF)

if(OPERA_BUILD_TESTS)
  message(STATUS "Building the OPERA tests")
  add_subdirectory(msbgatebootstrapping)
  add_subdirectory(comparison)
endif()
