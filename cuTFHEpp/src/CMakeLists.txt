file(GLOB cutfhe++_sources "*.c*")

add_library(
  cutfhe++
  STATIC
  ${cutfhe++_sources}
  )

target_include_directories(
  cutfhe++
  PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/../include
  )
