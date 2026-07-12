#include "update_installer.h"

#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <vector>

#include "ed25519/ed25519.h"

namespace update_installer {

namespace {

// The release-signing PUBLIC key (Ed25519, raw 32 bytes; provisioned
// 2026-07-12). CI signs Glimpr-Setup.exe with the matching private key (the
// RELEASE_SIGNING_KEY repo secret) and publishes the detached signature as
// Glimpr-Setup.exe.sig. Rotating the key = new constant here + a new release.
const unsigned char kReleasePubKey[32] = {
    0x2e, 0x47, 0xbb, 0xfb, 0x3c, 0xa9, 0x74, 0x41,
    0xb8, 0xb0, 0x79, 0x8e, 0xd9, 0x65, 0xc9, 0x16,
    0xa9, 0xa1, 0x4a, 0x90, 0x82, 0x2e, 0x61, 0xc4,
    0x9c, 0xe1, 0x2c, 0xbb, 0x72, 0x66, 0x02, 0x09,
};

// The Inno AppId's uninstall key (Inno appends _is1).
constexpr wchar_t kUninstallKey[] =
    L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\"
    L"{FA7E5DB0-A63A-4538-80F4-2E03416E3CFF}_is1";

std::wstring ExeDir() {
  wchar_t buf[MAX_PATH];
  DWORD n = GetModuleFileNameW(nullptr, buf, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return L"";
  std::wstring path(buf, n);
  size_t slash = path.find_last_of(L'\\');
  return slash == std::wstring::npos ? L"" : path.substr(0, slash);
}

std::wstring ExeFile() {
  wchar_t buf[MAX_PATH];
  DWORD n = GetModuleFileNameW(nullptr, buf, MAX_PATH);
  return (n == 0 || n >= MAX_PATH) ? L"" : std::wstring(buf, n);
}

// Lowercase + trim trailing separators, for path equality.
std::wstring Canon(std::wstring p) {
  while (!p.empty() && (p.back() == L'\\' || p.back() == L'/')) p.pop_back();
  std::transform(p.begin(), p.end(), p.begin(), [](wchar_t c) {
    return static_cast<wchar_t>(towlower(c));
  });
  return p;
}

std::wstring ReadInstallLocation(HKEY root) {
  wchar_t buf[MAX_PATH];
  DWORD size = sizeof(buf);
  if (RegGetValueW(root, kUninstallKey, L"InstallLocation", RRF_RT_REG_SZ,
                   nullptr, buf, &size) != ERROR_SUCCESS) {
    return L"";
  }
  return buf;
}

bool ReadAllBytes(const std::wstring& path, std::vector<unsigned char>* out) {
  std::ifstream f(path.c_str(), std::ios::binary | std::ios::ate);
  if (!f) return false;
  std::streamsize size = f.tellg();
  if (size <= 0) return false;
  out->resize(static_cast<size_t>(size));
  f.seekg(0);
  return static_cast<bool>(
      f.read(reinterpret_cast<char*>(out->data()), size));
}

}  // namespace

bool UpdateSupported() {
  const std::wstring exe_dir = Canon(ExeDir());
  if (exe_dir.empty()) return false;
  for (HKEY root : {HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER}) {
    const std::wstring loc = ReadInstallLocation(root);
    if (!loc.empty() && Canon(loc) == exe_dir) return true;
  }
  return false;
}

bool ApplyStaged(const std::wstring& exe_path, const std::wstring& sig_path) {
  if (!UpdateSupported()) return false;
  std::vector<unsigned char> exe_bytes;
  std::vector<unsigned char> sig_bytes;
  if (!ReadAllBytes(exe_path, &exe_bytes)) return false;
  if (!ReadAllBytes(sig_path, &sig_bytes) || sig_bytes.size() != 64) {
    return false;
  }
  if (ed25519_verify(sig_bytes.data(), exe_bytes.data(), exe_bytes.size(),
                     kReleasePubKey) != 1) {
    return false;
  }
  // Verified: drop the Mark-of-the-Web so the silent run is not gated.
  DeleteFileW((exe_path + L":Zone.Identifier").c_str());
  // Detached watcher (RelaunchApp's proven shape): wait for this process to
  // die (ping delay releases the single-instance mutex), run the installer
  // silently, then start the installed exe. `start` MUST NOT be used for the
  // installer (the watcher must block on it before relaunching).
  const std::wstring app_exe = ExeFile();
  if (app_exe.empty()) return false;
  // cmd strips the FIRST and LAST quote of the /c string, so every inner
  // path keeps ONE plain pair (RelaunchApp's proven quoting).
  wchar_t cmd[2048];
  swprintf_s(cmd,
             L"cmd.exe /c \"ping -n 3 127.0.0.1 >nul & \"%ls\" "
             L"/VERYSILENT /SUPPRESSMSGBOXES /NORESTART & "
             L"start \"\" \"%ls\"\"",
             exe_path.c_str(), app_exe.c_str());
  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi = {};
  if (!CreateProcessW(nullptr, cmd, nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
                      nullptr, nullptr, &si, &pi)) {
    return false;
  }
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return true;
}

}  // namespace update_installer
