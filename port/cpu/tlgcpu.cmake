# libtlgcpu.so: guest_cpu.h on FEXCore, linked statically against FEX's libraries (aarch64 hosts;
# from the Bloodborne ARM port's cpu/bbcpu.cmake).
set(TLGCPU_DIR "${CMAKE_CURRENT_LIST_DIR}")
add_library(tlgcpu SHARED "${TLGCPU_DIR}/guest_cpu_fex.cpp" "${TLGCPU_DIR}/host_call_arm64.S")
target_include_directories(tlgcpu PRIVATE "${TLGCPU_DIR}/../src" "${CMAKE_SOURCE_DIR}/Source" "${CMAKE_BINARY_DIR}/generated")
target_link_libraries(tlgcpu PRIVATE FEXCore Common JemallocLibs fmt::fmt)
target_compile_options(tlgcpu PRIVATE ${FEX_TUNE_COMPILE_FLAGS})
set_target_properties(tlgcpu PROPERTIES
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN TRUE)
