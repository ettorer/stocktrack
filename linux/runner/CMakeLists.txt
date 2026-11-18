cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

find_program(GLIB_COMPILE_RESOURCES glib-compile-resources REQUIRED)
set(STOCKTRACK_RESOURCE_C "${CMAKE_CURRENT_BINARY_DIR}/stocktrack_resources.c")
add_custom_command(
  OUTPUT "${STOCKTRACK_RESOURCE_C}"
  COMMAND "${GLIB_COMPILE_RESOURCES}"
    --generate-source
    --manual-register
    --c-name=stocktrack
    "--target=${STOCKTRACK_RESOURCE_C}"
    "--sourcedir=${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/stocktrack.gresource.xml"
  DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/stocktrack.gresource.xml"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../stocktrack.png"
  VERBATIM
)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "${STOCKTRACK_RESOURCE_C}"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
