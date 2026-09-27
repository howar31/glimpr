#ifndef RUNNER_CRASH_DUMP_PATH_H_
#define RUNNER_CRASH_DUMP_PATH_H_

#include <cwchar>

// Where crash minidumps go: "<LocalAppData>\Howar31\<app>\crashdumps". A
// per-user location is writable whether Glimpr is installed for all
// accounts (Program Files is read-only to the app) or for this account only,
// and it survives an install-scope switch or an uninstall like the rest of
// the user's data. Stack buffers only: the caller runs at startup, but the
// result is kept for the crash path, which must not touch the heap.
// Header-only so the native tests cover it.
namespace crash_dump_path {

// Appends src to dst (NUL-terminated, cap in wchar_t); false when it does
// not fit, in which case dst is emptied.
inline bool Append(wchar_t* dst, size_t cap, const wchar_t* src) {
  const size_t have = wcslen(dst);
  const size_t add = wcslen(src);
  if (have + add + 1 > cap) {
    dst[0] = 0;
    return false;
  }
  wcscpy_s(dst + have, cap - have, src);
  return true;
}

// Builds the dump directory from the LocalAppData known folder (with or
// without a trailing separator) and the build identity's app name. False
// (and an empty out) when the base is empty or the buffer is too small.
inline bool Build(const wchar_t* local_app_data, const wchar_t* app_name,
                  wchar_t* out, size_t cap) {
  if (cap == 0) return false;
  out[0] = 0;
  if (!local_app_data || local_app_data[0] == 0) return false;
  if (!Append(out, cap, local_app_data)) return false;
  size_t n = wcslen(out);
  while (n > 0 && (out[n - 1] == L'\\' || out[n - 1] == L'/')) out[--n] = 0;
  return Append(out, cap, L"\\Howar31\\") && Append(out, cap, app_name) &&
         Append(out, cap, L"\\crashdumps");
}

// The parent directory of path (last separator removed); false when there
// is no separator to cut at.
inline bool Parent(const wchar_t* path, wchar_t* out, size_t cap) {
  if (cap == 0) return false;
  out[0] = 0;
  const size_t n = wcslen(path);
  for (size_t i = n; i > 0; --i) {
    if (path[i - 1] == L'\\' || path[i - 1] == L'/') {
      if (i - 1 + 1 > cap) return false;
      wcsncpy_s(out, cap, path, i - 1);
      return out[0] != 0;
    }
  }
  return false;
}

}  // namespace crash_dump_path

#endif  // RUNNER_CRASH_DUMP_PATH_H_
