# Native unit tests for the Windows runner's pure logic. Kept out of the app
# build: the target is EXCLUDE_FROM_ALL so `flutter build windows` never touches
# it. Build + run explicitly (from the flutter-configured build dir):
#   cmake --build build/windows/x64 --target glimpr_tests --config Debug
#   build/windows/x64/test/Debug/glimpr_tests.exe
#
# Deliberately does NOT call apply_standard_settings, so it opts out of the
# runner's /WX (warnings-as-errors) and _HAS_EXCEPTIONS=0; the harness is a
# plain no-exception assert counter (test_main.cpp).
set(TEST_NAME "glimpr_tests")

add_executable(${TEST_NAME} EXCLUDE_FROM_ALL
  "test_main.cpp"
  # Compiled for the tone-map / half-float math (declared in hdr_util.h); the
  # other tested functions are header-only (base64.h / wav_parse.h /
  # pixel_swizzle.h / record_args.h) and need no extra sources.
  "${CMAKE_CURRENT_SOURCE_DIR}/../runner/hdr_util.cpp"
)

target_compile_features(${TEST_NAME} PRIVATE cxx_std_17)
target_compile_definitions(${TEST_NAME} PRIVATE "UNICODE" "_UNICODE" "NOMINMAX")
target_include_directories(${TEST_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../runner")
# hdr_util.cpp pulls in DXGI (HDR detect), DisplayConfig (user32) and the
# known-folder prefs probe (shell32 + ole32); the pure-math tests do not call
# them but the translation unit must still link.
target_link_libraries(${TEST_NAME} PRIVATE
  "dxgi.lib" "user32.lib" "shell32.lib" "ole32.lib")
# The vendored Ed25519 verifier (defined in ../runner/CMakeLists.txt) for the
# self-update signature-check vectors.
target_link_libraries(${TEST_NAME} PRIVATE ed25519_verify)
