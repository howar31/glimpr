#ifndef RUNNER_EDITOR_EXIT_GATE_H_
#define RUNNER_EDITOR_EXIT_GATE_H_

// When may the editor host process exit after the editor window was hidden?
// Only once nothing is left in flight: no export (setProcessing true), no
// sound still playing, and a settle period for the Dart side's deferred work
// (the tool-style persist timer, the GIF temp-dir cleanup). A hard bound
// keeps a stuck export from pinning the process forever. Header-only, pure,
// so the native tests cover it.
namespace egate {

constexpr unsigned long long kSettleMs = 1000;
constexpr unsigned long long kMaxMs = 10000;

struct Inputs {
  bool hidden = false;
  bool processing = false;
  bool sound_idle = true;
  unsigned long long now_ms = 0;
};

struct State {
  unsigned long long armed_ms = 0;        // when the window went hidden
  unsigned long long quiet_since_ms = 0;  // when the last blocker cleared
};

inline bool MayExit(const Inputs& in, State* st) {
  if (!in.hidden) {
    *st = State{};
    return false;
  }
  if (st->armed_ms == 0) st->armed_ms = in.now_ms;
  const bool bounded = in.now_ms - st->armed_ms >= kMaxMs;
  if (in.processing || !in.sound_idle) {
    st->quiet_since_ms = 0;
    return bounded;
  }
  if (st->quiet_since_ms == 0) {
    st->quiet_since_ms = in.now_ms;
    return bounded;
  }
  return in.now_ms - st->quiet_since_ms >= kSettleMs || bounded;
}

}  // namespace egate

#endif  // RUNNER_EDITOR_EXIT_GATE_H_
