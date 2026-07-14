#ifndef RUNNER_DROP_FILTER_H_
#define RUNNER_DROP_FILTER_H_

#include <cwctype>
#include <string>

// Drag-drop file filtering for the Image Editor window, header-only so the
// native test target can exercise it.
namespace dropfilter {

// True when [path] names a file type the editor can open. The extension list
// mirrors the editor's Open dialog filter (image_editor_app.dart _openPanel);
// macOS filters drops by UTType.image the same way.
inline bool IsEditorImagePath(const std::wstring& path) {
  const size_t dot = path.find_last_of(L'.');
  if (dot == std::wstring::npos) return false;
  const size_t slash = path.find_last_of(L"\\/");
  if (slash != std::wstring::npos && slash > dot) return false;
  std::wstring ext = path.substr(dot + 1);
  for (wchar_t& c : ext) c = static_cast<wchar_t>(std::towlower(c));
  static const wchar_t* kExts[] = {L"png", L"jpg",  L"jpeg", L"gif",
                                   L"webp", L"bmp", L"tiff"};
  for (const wchar_t* e : kExts) {
    if (ext == e) return true;
  }
  return false;
}

// True when [path] names a .gif -- the GIF Editor window's drop filter.
inline bool IsGifPath(const std::wstring& path) {
  const size_t dot = path.find_last_of(L'.');
  if (dot == std::wstring::npos) return false;
  const size_t slash = path.find_last_of(L"\\/");
  if (slash != std::wstring::npos && slash > dot) return false;
  std::wstring ext = path.substr(dot + 1);
  for (wchar_t& c : ext) c = static_cast<wchar_t>(std::towlower(c));
  return ext == L"gif";
}

}  // namespace dropfilter

#endif  // RUNNER_DROP_FILTER_H_
