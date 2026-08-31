#ifndef RUNNER_CLIPBOARD_HDROP_H_
#define RUNNER_CLIPBOARD_HDROP_H_

// Pure CF_HDROP payload construction, extracted for the native tests: the
// DROPFILES header followed by ONE wide path and the file list's second
// terminating null (an Explorer file copy's clipboard shape). The runner
// copies this into an HGLOBAL for SetClipboardData(CF_HDROP).

#include <windows.h>
#include <shlobj.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace clip {

// The CF_HDROP payload for a single file: DROPFILES + L"path\0\0".
inline std::vector<uint8_t> BuildDropFilesPayload(const std::wstring& path) {
  std::vector<uint8_t> out(sizeof(DROPFILES) +
                           (path.size() + 2) * sizeof(wchar_t));
  auto* drop = reinterpret_cast<DROPFILES*>(out.data());
  drop->pFiles = sizeof(DROPFILES);
  drop->fWide = TRUE;
  std::memcpy(out.data() + sizeof(DROPFILES), path.c_str(),
              (path.size() + 1) * sizeof(wchar_t));
  // The vector's zero-fill supplies the list's second terminating null.
  return out;
}

}  // namespace clip

#endif  // RUNNER_CLIPBOARD_HDROP_H_
