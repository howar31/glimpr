#include "crash_dump.h"

#include <windows.h>
// dbghelp.h must follow windows.h.
#include <dbghelp.h>

#include <cstdio>

namespace {

// One-shot guard: write at most one dump per process, so a faulting handler
// cannot loop and so a benign first-chance exception cannot pre-empt the real
// crash with repeated files.
LONG g_dumped = 0;

// Writes a minidump to "<dir-of-exe>\crashdumps\glimpr-<tag>-<pid>-<tick>.dmp".
// Deliberately uses only stack buffers + Win32 calls (no heap), so it still works
// when the crash is heap corruption. |tag| is a short ASCII/wide literal.
void WriteDump(EXCEPTION_POINTERS* ep, const wchar_t* tag) {
  if (::InterlockedExchange(&g_dumped, 1) != 0) return;

  wchar_t exe[MAX_PATH];
  DWORD n = ::GetModuleFileNameW(nullptr, exe, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return;
  for (DWORD i = n; i > 0; --i) {
    if (exe[i - 1] == L'\\' || exe[i - 1] == L'/') {
      exe[i - 1] = 0;
      break;
    }
  }

  wchar_t dir[MAX_PATH];
  if (_snwprintf_s(dir, MAX_PATH, _TRUNCATE, L"%s\\crashdumps", exe) < 0) return;
  ::CreateDirectoryW(dir, nullptr);

  wchar_t file[MAX_PATH];
  if (_snwprintf_s(file, MAX_PATH, _TRUNCATE, L"%s\\glimpr-%s-%lu-%llu.dmp", dir,
                   tag, ::GetCurrentProcessId(),
                   static_cast<unsigned long long>(::GetTickCount64())) < 0) {
    return;
  }

  HANDLE f = ::CreateFileW(file, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) return;

  MINIDUMP_EXCEPTION_INFORMATION mei{};
  mei.ThreadId = ::GetCurrentThreadId();
  mei.ExceptionPointers = ep;
  mei.ClientPointers = FALSE;

  // Normal + thread info + unloaded modules: enough to read the faulting thread's
  // stack and the loaded-module list (to see whether a foreign hook DLL is in our
  // address space / on the stack) without a bulky full-memory dump.
  const MINIDUMP_TYPE type = static_cast<MINIDUMP_TYPE>(
      MiniDumpNormal | MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules);
  ::MiniDumpWriteDump(::GetCurrentProcess(), ::GetCurrentProcessId(), f, type,
                      ep ? &mei : nullptr, nullptr, nullptr);
  ::CloseHandle(f);
}

LONG WINAPI UnhandledFilter(EXCEPTION_POINTERS* ep) {
  WriteDump(ep, L"unhandled");
  return EXCEPTION_EXECUTE_HANDLER;  // proceed to terminate
}

LONG WINAPI VectoredFilter(EXCEPTION_POINTERS* ep) {
  // STATUS_FATAL_USER_CALLBACK_EXCEPTION: an exception propagating out of a user
  // callback across the kernel boundary (e.g. a foreign window hook subclassing
  // our window faults). It is always fatal AND bypasses the unhandled filter, so
  // capture it here. It is never benign -> no false positives. Continue the
  // search so normal (fatal) handling still runs.
  if (ep && ep->ExceptionRecord &&
      ep->ExceptionRecord->ExceptionCode == 0xC000041DL) {
    WriteDump(ep, L"callback");
  }
  return EXCEPTION_CONTINUE_SEARCH;
}

}  // namespace

void InstallCrashHandler() {
  ::SetUnhandledExceptionFilter(UnhandledFilter);
  ::AddVectoredExceptionHandler(0, VectoredFilter);
}
