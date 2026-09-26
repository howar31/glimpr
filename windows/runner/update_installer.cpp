#include "update_installer.h"

#include <windows.h>

#include <shellapi.h>

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <vector>

#include "ed25519/ed25519.h"
#include "instance_mutex.h"

namespace update_installer {

namespace {

// The release-signing PUBLIC key (Ed25519, raw 32 bytes; provisioned
// 2026-07-12). CI signs the Glimpr-Setup-<version>.exe asset with the
// matching private key (the RELEASE_SIGNING_KEY repo secret) and publishes
// the detached signature as <asset>.sig. Rotating the key = new constant
// here + a new release.
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

// 8.3 short names (a shortcut or launcher may hand us C:\PROGRA~1\...) must
// compare equal to the registry's long form; expansion needs the path to
// exist, which both compared paths do.
std::wstring LongPath(const std::wstring& p) {
  wchar_t buf[MAX_PATH];
  DWORD n = GetLongPathNameW(p.c_str(), buf, MAX_PATH);
  return (n == 0 || n >= MAX_PATH) ? p : std::wstring(buf, n);
}

// Long-form + lowercase + trim trailing separators, for path equality.
std::wstring Canon(std::wstring p) {
  p = LongPath(p);
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

ApplyResult ApplyStaged(const std::wstring& exe_path,
                        const std::wstring& sig_path) {
  if (!UpdateSupported()) return ApplyResult::kRejected;
  std::vector<unsigned char> exe_bytes;
  std::vector<unsigned char> sig_bytes;
  if (!ReadAllBytes(exe_path, &exe_bytes)) return ApplyResult::kRejected;
  if (!ReadAllBytes(sig_path, &sig_bytes) || sig_bytes.size() != 64) {
    return ApplyResult::kRejected;
  }
  if (ed25519_verify(sig_bytes.data(), exe_bytes.data(), exe_bytes.size(),
                     kReleasePubKey) != 1) {
    return ApplyResult::kRejected;
  }
  // Verified: drop the Mark-of-the-Web so the silent run is not gated.
  DeleteFileW((exe_path + L":Zone.Identifier").c_str());
  // The installer's manifest requests administrator rights, so ShellExecuteEx
  // raises the elevation prompt here, with this app still running. Its
  // AppMutex check would refuse to start while our single-instance mutex
  // exists, so the mutex goes first (and comes back on a decline).
  wchar_t params[128];
  swprintf_s(params, L"/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /PID=%lu",
             GetCurrentProcessId());
  SHELLEXECUTEINFOW sei = {};
  sei.cbSize = sizeof(sei);
  sei.fMask = SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC;
  sei.lpVerb = L"open";
  sei.lpFile = exe_path.c_str();
  sei.lpParameters = params;
  sei.nShow = SW_SHOWNORMAL;
  instance_mutex::Release();
  if (!ShellExecuteExW(&sei)) {
    const DWORD err = GetLastError();
    instance_mutex::Reacquire();
    return err == ERROR_CANCELLED ? ApplyResult::kCancelled
                                  : ApplyResult::kRejected;
  }
  return ApplyResult::kLaunched;
}

}  // namespace update_installer
