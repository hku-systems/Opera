file(GLOB opera_sources "*.c*")

add_library(
  opera
  STATIC
  ${opera_sources}
  )

target_include_directories(
  opera
  PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/../include
  ${CMAKE_CURRENT_SOURCE_DIR}/../thirdparty/phantom-fhe/include
  )
