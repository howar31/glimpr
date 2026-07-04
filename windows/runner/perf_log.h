#ifndef RUNNER_PERF_LOG_H_
#define RUNNER_PERF_LOG_H_

#include <string>

// Debug-gated perf marks: the Windows analogue of the macOS PerfLog + unified
// log. Fully inert in normal use (owner mandate): the gate is read ONCE at
// launch and a disabled gate costs one cached-bool check per mark, creates no
// file, and never touches the disk.
namespace perf {

// Reads the shared `debugHooks` gate once (call early in wWinMain, before any
// mark) and opens the log file when it is on. The gate is the SAME
// shared_preferences key the Dart perf gate reads, so one switch arms both
// sides (mirrors macOS `defaults write com.howar31.glimpr debugHooks`).
void Init();

// True when the debugHooks gate was on at launch.
bool Enabled();

// Append "<ms-since-launch> <label>" to
// %APPDATA%\com.example\glimpr\perf.log (QPC-based, agent-readable over SSH).
// No-op when the gate is off. Thread-safe.
void Mark(const std::string& label);

}  // namespace perf

#endif  // RUNNER_PERF_LOG_H_
