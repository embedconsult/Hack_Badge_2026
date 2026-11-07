idf_component_register(SRCS "main.c" "ota.c" "net.c" "apps.c" "qr.c" "settings.c" "b2b.c"
                            "apps_net.c" "apps_gfx.c" "feed.c" "weather.c" "radar.c" "stb_image_impl.c"
                            "snakes.c" "snakes_net.c" "robots.c"
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

add_custom_command(
  OUTPUT "${CRYSTAL_OBJ}"
  # CRYSTAL_LIBRARY_PATH is set explicitly so the compiler doesn't need
  # /proc/self/exe to expand $ORIGIN (no /proc in the build chroot).
  COMMAND ${CMAKE_COMMAND} -E env
          "CRYSTAL_PATH=${CRYSTAL_HOME}/src"
          "CRYSTAL_LIBRARY_PATH=${CRYSTAL_HOME}/lib"
          "CRYSTAL_CACHE_DIR=${CMAKE_CURRENT_BINARY_DIR}/crystal-cache"
          # -O2, not --release (-O3): Xtensa L32R reaches literals at most
          # 256 KiB back and the whole program is one .text section; at -O3
          # it outgrew that (291 KiB with ROBOTS; -O2 216 KiB, -Os 161 KiB;
          # measure with test/robots/crystal_size.sh).
          "${CRYSTAL_XTENSA}" build --prelude=empty --cross-compile
          --target xtensa-esp-unknown-elf --mcpu esp32s3 -O2 --single-module
          -o "${CRYSTAL_OBJ_BASE}" "${CRYSTAL_MAIN}"
  # Crystal always emits a C-style `main`; keep it out of the global namespace.
  COMMAND ${CMAKE_OBJCOPY} --localize-symbol=main "${CRYSTAL_OBJ}"
  DEPENDS ${CRYSTAL_SOURCES}
  COMMENT "Crystal: compiling ${CRYSTAL_MAIN} for Xtensa (esp32s3)"
  VERBATIM)

set_source_files_properties("${CRYSTAL_OBJ}" PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)
target_sources(${COMPONENT_LIB} PRIVATE "${CRYSTAL_OBJ}")
