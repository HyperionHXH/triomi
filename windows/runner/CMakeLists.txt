cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

option(TRIOMI_MIHON_ACCEPTANCE_BUILD "Allow only isolated local Mihon acceptance roots" OFF)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "windows_backup.cpp"
  "app_update.cpp"
  "windows_web_session.cpp"
  "desktop_mihon_runtime.cpp"
  "windows_file_actions.cpp"
  "windows_playback_feedback.cpp"
  "windows_update_install.cpp"
  "windows_system_media.cpp"
  "windows_content_updates.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})
target_compile_options(${BINARY_NAME} PRIVATE /utf-8)

if(TRIOMI_MIHON_ACCEPTANCE_BUILD)
  target_compile_definitions(${BINARY_NAME} PRIVATE TRIOMI_MIHON_ACCEPTANCE_BUILD
    "$<$<CONFIG:Release>:TRIOMI_MIHON_ACCEPTANCE_RELEASE_FORBIDDEN>")
endif()

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib" "taskschd.lib" "ole32.lib" "oleaut32.lib" "advapi32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "version.lib" "shell32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "winhttp.lib"
  "${CMAKE_BINARY_DIR}/triomi-webview-packages/Microsoft.Web.WebView2/build/native/Microsoft.Web.WebView2.targets")
target_link_libraries(${BINARY_NAME} PRIVATE bcrypt uuid)
target_link_libraries(${BINARY_NAME} PRIVATE windowsapp runtimeobject)

add_executable(triomi_update_helper WIN32 "windows_update_helper.cpp")
apply_standard_settings(triomi_update_helper)
target_compile_options(triomi_update_helper PRIVATE /utf-8)
target_compile_definitions(triomi_update_helper PRIVATE NOMINMAX)
target_link_libraries(triomi_update_helper PRIVATE bcrypt advapi32 shell32 ole32 uuid version user32)
add_dependencies(${BINARY_NAME} triomi_update_helper)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
