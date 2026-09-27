#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <iostream>
#include <vector>

#include "version_string.h"

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  // First, find the length of the string with a safe upper bound (CWE-126).
  // UNICODE_STRING_MAX_CHARS (32767) is the maximum length of a UNICODE_STRING.
  int input_length = static_cast<int>(wcsnlen(utf16_string, UNICODE_STRING_MAX_CHARS));
  // Now use that bounded length to determine the required buffer size.
  // When an explicit length is passed, WideCharToMultiByte does not include
  // the null terminator in its returned size.
  int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, nullptr, 0, nullptr, nullptr);
  std::string utf8_string;
  if (target_length == 0 || static_cast<size_t>(target_length) > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}

std::string Utf8FromUtf16(const std::wstring& utf16) {
  if (utf16.empty()) return {};
  int n = ::WideCharToMultiByte(CP_UTF8, 0, utf16.c_str(),
                                static_cast<int>(utf16.size()), nullptr, 0,
                                nullptr, nullptr);
  if (n <= 0) return {};
  std::string s(static_cast<size_t>(n), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, utf16.c_str(),
                        static_cast<int>(utf16.size()), s.data(), n, nullptr,
                        nullptr);
  return s;
}

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) return {};
  int n = ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                static_cast<int>(utf8.size()), nullptr, 0);
  if (n <= 0) return {};
  std::wstring w(static_cast<size_t>(n), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                        static_cast<int>(utf8.size()), w.data(), n);
  return w;
}

namespace {
bool ReadFixedFileInfo(VS_FIXEDFILEINFO* out) {
  wchar_t path[MAX_PATH];
  if (GetModuleFileNameW(nullptr, path, MAX_PATH) == 0) return false;
  DWORD handle = 0;
  DWORD size = GetFileVersionInfoSizeW(path, &handle);
  if (size == 0) return false;
  std::vector<BYTE> data(size);
  if (!GetFileVersionInfoW(path, 0, size, data.data())) return false;
  VS_FIXEDFILEINFO* info = nullptr;
  UINT len = 0;
  if (!VerQueryValueW(data.data(), L"\\", reinterpret_cast<LPVOID*>(&info),
                      &len) ||
      !info) {
    return false;
  }
  *out = *info;
  return true;
}
}  // namespace

namespace {

// The ProductVersion string from the exe's version resource (any language
// block), or "" when absent. Kept next to the numeric reader above as the
// fallback source for both version strings.
std::string ReadProductVersionString() {
  wchar_t path[MAX_PATH];
  if (GetModuleFileNameW(nullptr, path, MAX_PATH) == 0) return "";
  DWORD handle = 0;
  DWORD size = GetFileVersionInfoSizeW(path, &handle);
  if (size == 0) return "";
  std::vector<BYTE> data(size);
  if (!GetFileVersionInfoW(path, 0, size, data.data())) return "";
  struct LangCodePage {
    WORD language;
    WORD code_page;
  };
  LangCodePage* translations = nullptr;
  UINT len = 0;
  if (!VerQueryValueW(data.data(), L"\\VarFileInfo\\Translation",
                      reinterpret_cast<LPVOID*>(&translations), &len) ||
      !translations) {
    return "";
  }
  for (UINT i = 0; i < len / sizeof(LangCodePage); ++i) {
    wchar_t query[64];
    swprintf_s(query, L"\\StringFileInfo\\%04x%04x\\ProductVersion",
               translations[i].language, translations[i].code_page);
    wchar_t* value = nullptr;
    UINT value_len = 0;
    if (VerQueryValueW(data.data(), query, reinterpret_cast<LPVOID*>(&value),
                       &value_len) &&
        value && value_len > 0) {
      return Utf8FromUtf16(std::wstring(value));
    }
  }
  return "";
}

// Marketing + build from the ProductVersion string; the numeric fields are
// the fallback when the string is missing (they cannot carry a prerelease)
// and supply the build number when the string carries none (the Flutter
// tool drops the +build part when only a build name is passed).
bool ReadVersionParts(std::string* marketing, std::string* build) {
  const bool from_string =
      version_string::Split(ReadProductVersionString(), marketing, build);
  if (from_string && !build->empty()) return true;
  VS_FIXEDFILEINFO info{};
  if (!ReadFixedFileInfo(&info)) return from_string;
  if (!from_string) {
    char m[48];
    sprintf_s(m, "%u.%u.%u", HIWORD(info.dwProductVersionMS),
              LOWORD(info.dwProductVersionMS),
              HIWORD(info.dwProductVersionLS));
    *marketing = m;
  }
  const unsigned build_number = LOWORD(info.dwProductVersionLS);
  if (build_number != 0) {
    char b[16];
    sprintf_s(b, "%u", build_number);
    *build = b;
  }
  return true;
}

}  // namespace

std::string AppVersionString() {
  std::string marketing, build;
  if (!ReadVersionParts(&marketing, &build)) return "";
  return version_string::Display(marketing, build);
}

std::string AppMarketingVersion() {
  std::string marketing, build;
  if (!ReadVersionParts(&marketing, &build)) return "";
  return marketing;
}
