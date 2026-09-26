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

install_scope::Scope CurrentScope() {
  const std::wstring exe_dir = Canon(ExeDir());
  if (exe_dir.empty()) return install_scope::Scope::kNone;
  const std::wstring machine = ReadInstallLocation(HKEY_LOCAL_MACHINE);
  if (!machine.empty() && Canon(machine) == exe_dir) {
    return install_scope::Scope::kMachine;
  }
  const std::wstring user = ReadInstallLocation(HKEY_CURRENT_USER);
  if (!user.empty() && Canon(user) == exe_dir) {
    return install_scope::Scope::kUser;
  }
  return install_scope::Scope::kNone;
}

bool UpdateSupported() {
  return CurrentScope() != install_scope::Scope::kNone;
}

bool IsAdminAccount() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE,
                        &token)) {
    return false;
  }
  // Under UAC an administrator's interactive process holds a FILTERED
  // token; membership must be judged on the linked full token, or every
  // administrator account would read as a standard user.
  HANDLE judged = token;
  HANDLE linked = nullptr;
  TOKEN_ELEVATION_TYPE type = TokenElevationTypeDefault;
  DWORD n = 0;
  if (GetTokenInformation(token, TokenElevationType, &type, sizeof(type),
                          &n) &&
      type == TokenElevationTypeLimited) {
    TOKEN_LINKED_TOKEN lt = {};
    if (GetTokenInformation(token, TokenLinkedToken, &lt, sizeof(lt), &n)) {
      linked = lt.LinkedToken;
      judged = linked;
    }
  }
  bool admin = false;
  // CheckTokenMembership wants an impersonation token.
  HANDLE imp = nullptr;
  if (DuplicateToken(judged, SecurityIdentification, &imp)) {
    SID_IDENTIFIER_AUTHORITY nt = SECURITY_NT_AUTHORITY;
    PSID admins = nullptr;
    if (AllocateAndInitializeSid(&nt, 2, SECURITY_BUILTIN_DOMAIN_RID,
                                 DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0,
                                 &admins)) {
      BOOL member = FALSE;
      if (CheckTokenMembership(imp, admins, &member)) admin = member != FALSE;
      FreeSid(admins);
    }
    CloseHandle(imp);
  }
  if (linked) CloseHandle(linked);
  CloseHandle(token);
  return admin;
}

ApplyResult ApplyStaged(const std::wstring& exe_path,
                        const std::wstring& sig_path,
                        install_scope::Target target) {
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
  // The installer's manifest no longer asks for administrator rights (it
  // installs per user by default), so elevation is OUR choice: the runas
  // verb whenever a machine scope is involved, plain open otherwise. Either
  // way the app is still running, so a declined prompt leaves it untouched.
  // Setup's AppMutex check would refuse to start while our single-instance
  // mutex exists, so the mutex goes first (and comes back on a decline).
  const install_scope::Scope current = CurrentScope();
  const install_scope::Scope effective =
      install_scope::Effective(current, target);
  const std::wstring params =
      install_scope::InstallerParams(effective, GetCurrentProcessId());
  const bool elevate = install_scope::NeedsElevation(current, effective);
  SHELLEXECUTEINFOW sei = {};
  sei.cbSize = sizeof(sei);
  sei.fMask = SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC;
  sei.lpVerb = elevate ? L"runas" : L"open";
  sei.lpFile = exe_path.c_str();
  sei.lpParameters = params.c_str();
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
