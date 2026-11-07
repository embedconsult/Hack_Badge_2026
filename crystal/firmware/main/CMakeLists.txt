idf_component_register(SRCS "main.c" "ota.c" "net.c" "apps.c" "qr.c" "settings.c"
                       EMBED_FILES "hello_i_am_blank.png" "portrait.png" "sketch_frame.png" "EtchASketch.png"
                       PRIV_REQUIRES esp_driver_gpio esp_driver_spi esp_driver_rmt esp_adc nvs_flash esp_timer esp_rom heap freertos
                                     esp_wifi esp_netif lwip esp_event esp_http_client esp_http_server esp_https_ota app_update esp_app_format mbedtls)

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

add_custom_command(
  OUTPUT "${CRYSTAL_OBJ}"
  # CRYSTAL_LIBRARY_PATH is set explicitly so the compiler doesn't need
  # /proc/self/exe to expand $ORIGIN (no /proc in the build chroot).
  COMMAND ${CMAKE_COMMAND} -E env
          "CRYSTAL_PATH=${CRYSTAL_HOME}/src"
          "CRYSTAL_LIBRARY_PATH=${CRYSTAL_HOME}/lib"
          "CRYSTAL_CACHE_DIR=${CMAKE_CURRENT_BINARY_DIR}/crystal-cache"
          "${CRYSTAL_XTENSA}" build --prelude=empty --cross-compile
          --target xtensa-esp-unknown-elf --mcpu esp32s3 --release
          -o "${CRYSTAL_OBJ_BASE}" "${CRYSTAL_MAIN}"
  # Crystal always emits a C-style `main`; keep it out of the global namespace.
  COMMAND ${CMAKE_OBJCOPY} --localize-symbol=main "${CRYSTAL_OBJ}"
  DEPENDS ${CRYSTAL_SOURCES}
  COMMENT "Crystal: compiling ${CRYSTAL_MAIN} for Xtensa (esp32s3)"
  VERBATIM)

set_source_files_properties("${CRYSTAL_OBJ}" PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)
target_sources(${COMPONENT_LIB} PRIVATE "${CRYSTAL_OBJ}")
