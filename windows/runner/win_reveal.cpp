#include "win_reveal.h"

#include <windows.h>

#include <shlobj.h>

void RevealInExplorer(const std::string& utf8_path) {
  if (utf8_path.empty()) return;
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8_path.c_str(), -1, nullptr, 0);
  if (n <= 0) return;
  std::wstring w(static_cast<size_t>(n - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8_path.c_str(), -1, w.data(), n);

  // SHOpenFolderAndSelectItems needs COM on this thread; balance the ref count.
  const bool com = SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED));
  PIDLIST_ABSOLUTE pidl = nullptr;
  if (SUCCEEDED(SHParseDisplayName(w.c_str(), nullptr, &pidl, 0, nullptr)) &&
      pidl) {
    SHOpenFolderAndSelectItems(pidl, 0, nullptr, 0);
    CoTaskMemFree(pidl);
  }
  if (com) CoUninitialize();
}
