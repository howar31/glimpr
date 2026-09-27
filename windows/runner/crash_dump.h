#ifndef RUNNER_CRASH_DUMP_H_
#define RUNNER_CRASH_DUMP_H_

// Installs best-effort crash capture for this process: an unhandled-exception
// filter plus a vectored handler for STATUS_FATAL_USER_CALLBACK_EXCEPTION (a
// foreign window-hook / window-proc callback faulting inside our message pump,
// which bypasses the unhandled filter). Either writes a minidump to
// "<LocalAppData>\Howar31\<app>\crashdumps" (see crash_dump_path.h). Call
// once, as early as possible in wWinMain. Safe to call in the record-worker
// process too.
void InstallCrashHandler();

// The resolved dump directory (empty before InstallCrashHandler or when no
// location could be resolved); reported in the diagnostics snapshot.
const wchar_t* CrashDumpDir();

#endif  // RUNNER_CRASH_DUMP_H_
