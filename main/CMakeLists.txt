set(DEPS nvs_flash)
if(CONFIG_ESP_WIFI_ENABLED)
    list(APPEND DEPS esp_wifi esp_netif esp_event)
endif()
if(CONFIG_BT_ENABLED)
    list(APPEND DEPS bt)
endif()

idf_component_register(
    SRCS "placeholder.c"  # Minimal C file required by CMake      
    INCLUDE_DIRS "." "${CMAKE_SOURCE_DIR}/include"
    REQUIRES ${DEPS}
)

# To use different project root
# ZIG_EXAMPLE_ARG is passed as argument to zig build
set(ZIG_EXAMPLE_ARG "") # default is main/app.zig
if(ZIG_PROJECT_ROOT)
  set(ZIG_EXAMPLE_ARG "-Dproject-root=${ZIG_PROJECT_ROOT}")
endif()

# Include the Zig build system 
include(${CMAKE_SOURCE_DIR}/cmake/zig-config.cmake)

# FIXME: need add <cmath> for build kalman
if(TARGET __idf_espressif__esp-dsp AND IDF_VERSION_MAJOR EQUAL 6)
    target_compile_options(__idf_espressif__esp-dsp PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:-includecmath>
    )
endif()

