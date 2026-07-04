#include "win_reveal.h"

#include <windows.h>

#include <shlobj.h>

#include "utils.h"

void RevealInExplorer(const std::string& utf8_path) {
  const std::wstring w = Utf16FromUtf8(utf8_path);
  if (w.empty()) return;

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
