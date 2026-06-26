cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "capture_channel.cpp"
  "clipboard_channel.cpp"
  "cursor_image.cpp"
  "decoration.cpp"
  "editor_window.cpp"
  "encode_channel.cpp"
  "flutter_window.cpp"
  "hotkey_host.cpp"
  "image_codec.cpp"
  "main.cpp"
  "overlay_manager.cpp"
  "overlay_window.cpp"
  "tray_icon.cpp"
  "utils.cpp"
  "wgc_capturer.cpp"
  "win32_window.cpp"
  "window_enum.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

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
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# Graphics libs for native capture (Windows.Graphics.Capture, D3D11, Direct2D,
# WIC) and the WinRT umbrella. Added in Phase 6 S2a.
target_link_libraries(${BINARY_NAME} PRIVATE "d3d11.lib" "dxgi.lib" "d2d1.lib" "windowscodecs.lib" "windowsapp.lib" "ole32.lib" "shcore.lib")
# Resident shell (Phase 6 S3): tray + ShellExecute (shell32), VERSIONINFO
# (version), launch-at-login registry (advapi32).
target_link_libraries(${BINARY_NAME} PRIVATE "shell32.lib" "version.lib" "advapi32.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
