idf_component_register(SRCS "main.c" "ota.c" "net.c" "apps.c" "qr.c" "settings.c" "b2b.c"
                            "apps_net.c" "apps_gfx.c" "feed.c" "weather.c" "radar.c" "stb_image_impl.c"
                            "snakes.c" "snakes_net.c" "robots.c" "robonet.c"
                       EMBED_FILES "hello_i_am_blank.png" "portrait.png" "sketch_frame.png" "EtchASketch.png" "schedule.csv"
                       PRIV_REQUIRES esp_driver_gpio esp_driver_spi esp_driver_rmt esp_adc nvs_flash esp_timer esp_rom heap freertos
                                     esp_wifi esp_netif lwip esp_event esp_http_client esp_http_server esp_https_ota app_update esp_app_format mbedtls json
                                     usb usb_host_cdc_acm spi_flash esp_partition bootloader_support)

# --- Crystal -> Xtensa object --------------------------------------------------
# Needs the xtensa-patched Crystal compiler (see ../../toolchain/README.md).
if(DEFINED ENV{CRYSTAL_XTENSA})
  set(CRYSTAL_XTENSA "$ENV{CRYSTAL_XTENSA}")
else()
  set(CRYSTAL_XTENSA "/opt/crystal-xtensa/bin/crystal")
endif()
get_filename_component(CRYSTAL_HOME "${CRYSTAL_XTENSA}" DIRECTORY)
get_filename_component(CRYSTAL_HOME "${CRYSTAL_HOME}" DIRECTORY)

set(CRYSTAL_SRC_DIR "${CMAKE_CURRENT_LIST_DIR}/../src")
set(CRYSTAL_MAIN "${CRYSTAL_SRC_DIR}/main.cr")
file(GLOB_RECURSE CRYSTAL_SOURCES CONFIGURE_DEPENDS "${CRYSTAL_SRC_DIR}/*.cr")
set(CRYSTAL_OBJ_BASE "${CMAKE_CURRENT_BINARY_DIR}/crystal_app")
set(CRYSTAL_OBJ "${CRYSTAL_OBJ_BASE}.o")

# Optimisation and literal placement (see ../../toolchain/README.md,
# "Literal pools"). build.sh writes crystal_flags.cmake from the env vars
# CRYSTAL_OPT, CRYSTAL_SPLIT and CRYSTAL_LLC_FLAGS; a plain idf.py build reads
# the env directly.
#   CRYSTAL_OPT    crystal optimisation flags, default -O2. --release (-O3)
#                  needs CRYSTAL_SPLIT=1: Xtensa L32R reaches literals at most
#                  256 KiB back and Crystal emits one .literal + one .text
#                  section, so at -O3 (305 KiB) the link fails with
#                  "dangerous relocation: l32r: literal target out of range".
#   CRYSTAL_SPLIT  0 (default): Crystal writes the object itself.
#                  1: Crystal emits its optimised LLVM IR, crystal_sections.py
#                  gives each function a .text.<name> section (so its literal
#                  pool gets .literal.<name>, which the IDF linker script keeps
#                  right before it; --gc-sections then also drops unused
#                  functions), and esp-clang's llc writes the object.
#   CRYSTAL_LLC_FLAGS  extra llc flags with CRYSTAL_SPLIT=1, e.g.
#                  --mtext-section-literals (pools inline in .text.<name>).
set(CRYSTAL_OPT "$ENV{CRYSTAL_OPT}")
set(CRYSTAL_SPLIT "$ENV{CRYSTAL_SPLIT}")
set(CRYSTAL_LLC_FLAGS "$ENV{CRYSTAL_LLC_FLAGS}")
set(CRYSTAL_FLAGS_FILE "${CMAKE_CURRENT_LIST_DIR}/crystal_flags.cmake")
if(EXISTS "${CRYSTAL_FLAGS_FILE}")
  include("${CRYSTAL_FLAGS_FILE}")   # also makes it a configure dependency
else()
  set(CRYSTAL_FLAGS_FILE "")
endif()
if(CRYSTAL_OPT STREQUAL "")
  set(CRYSTAL_OPT "-O2")
endif()
separate_arguments(CRYSTAL_OPT_LIST UNIX_COMMAND "${CRYSTAL_OPT}")
separate_arguments(CRYSTAL_LLC_LIST UNIX_COMMAND "${CRYSTAL_LLC_FLAGS}")
if(CRYSTAL_OPT MATCHES "--release|-O3")
  set(CRYSTAL_LLC_O "-O3")
elseif(CRYSTAL_OPT MATCHES "-O1")
  set(CRYSTAL_LLC_O "-O1")
elseif(CRYSTAL_OPT MATCHES "-O0")
  set(CRYSTAL_LLC_O "-O0")
else()
  set(CRYSTAL_LLC_O "-O2")   # Crystal uses the default codegen level for -O2/-Os/-Oz
endif()
if(DEFINED ENV{CRYSTAL_LLC_BIN})
  set(CRYSTAL_LLC_BIN "$ENV{CRYSTAL_LLC_BIN}")
else()
  set(CRYSTAL_LLC_BIN "/opt/esp-clang/bin/llc")   # same LLVM the compiler links
endif()
message(STATUS "Crystal: ${CRYSTAL_OPT}, split: '${CRYSTAL_SPLIT}', llc flags: '${CRYSTAL_LLC_FLAGS}'")

set(CRYSTAL_ENV ${CMAKE_COMMAND} -E env
    # CRYSTAL_LIBRARY_PATH is set explicitly so the compiler doesn't need
    # /proc/self/exe to expand $ORIGIN (no /proc in the build chroot).
    "CRYSTAL_PATH=${CRYSTAL_HOME}/src"
    "CRYSTAL_LIBRARY_PATH=${CRYSTAL_HOME}/lib"
    "CRYSTAL_CACHE_DIR=${CMAKE_CURRENT_BINARY_DIR}/crystal-cache")
set(CRYSTAL_BUILD "${CRYSTAL_XTENSA}" build --prelude=empty --cross-compile
    --target xtensa-esp-unknown-elf --mcpu esp32s3 ${CRYSTAL_OPT_LIST} --single-module)

if(NOT CRYSTAL_SPLIT)
  set(CRYSTAL_COMPILE
      COMMAND ${CRYSTAL_ENV} ${CRYSTAL_BUILD} -o "${CRYSTAL_OBJ_BASE}" "${CRYSTAL_MAIN}")
else()
  # --emit llvm-ir writes the IR after Crystal's optimisation pipeline (the
  # .o Crystal also writes is overwritten). llc gets the target machine
  # settings Crystal uses: static relocs, no GlobalISel.
  idf_build_get_property(python PYTHON)
  set(CRYSTAL_COMPILE
      COMMAND ${CRYSTAL_ENV} ${CRYSTAL_BUILD} --emit llvm-ir -o "${CRYSTAL_OBJ_BASE}" "${CRYSTAL_MAIN}"
      COMMAND ${python} "${CMAKE_CURRENT_LIST_DIR}/crystal_sections.py"
              "${CRYSTAL_OBJ_BASE}.ll" "${CRYSTAL_OBJ_BASE}.split.ll"
      COMMAND "${CRYSTAL_LLC_BIN}" -mtriple=xtensa-esp-unknown-elf -mcpu=esp32s3
              -relocation-model=static -global-isel=0 ${CRYSTAL_LLC_O} ${CRYSTAL_LLC_LIST}
              -filetype=obj -o "${CRYSTAL_OBJ}" "${CRYSTAL_OBJ_BASE}.split.ll")
endif()

add_custom_command(
  OUTPUT "${CRYSTAL_OBJ}"
  ${CRYSTAL_COMPILE}
  # Crystal always emits a C-style `main`; keep it out of the global namespace.
  COMMAND ${CMAKE_OBJCOPY} --localize-symbol=main "${CRYSTAL_OBJ}"
  DEPENDS ${CRYSTAL_SOURCES} ${CRYSTAL_FLAGS_FILE} "${CMAKE_CURRENT_LIST_DIR}/crystal_sections.py"
  COMMENT "Crystal: compiling ${CRYSTAL_MAIN} for Xtensa (esp32s3)"
  VERBATIM)

set_source_files_properties("${CRYSTAL_OBJ}" PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)
target_sources(${COMPONENT_LIB} PRIVATE "${CRYSTAL_OBJ}")
