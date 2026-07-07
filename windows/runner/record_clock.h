#ifndef RUNNER_RECORD_CLOCK_H_
#define RUNNER_RECORD_CLOCK_H_

#include <windows.h>

#include <cstdint>

// QueryPerformanceCounter as 100ns ticks. ONE clock shared by the video
// capture (WGC) and the audio capture (WASAPI) so their timestamps are
// comparable: WGC SystemRelativeTime and WASAPI u64QPCPosition are on
// DIFFERENT epochs, and subtracting one from the other produced a
// giant-negative audio pts -> clamped to 0 -> the whole audio track crammed
// at pts~0 ("mic only plays ~1 second"). Audio reads this at packet receipt
// rather than trusting the driver's u64QPCPosition (some drivers leave it
// 0 / on a different epoch).
// Convert a raw QPC [counter] at [freq] ticks/sec to 100ns units. Split
// seconds + remainder so counter * 1e7 cannot overflow int64 (counter is ~1e12
// on a machine up for a day; *1e7 would exceed int64 max). Pure -- extracted so
// the overflow-split is unit-testable without a live QPC.
inline int64_t Qpc100nsFrom(int64_t counter, int64_t freq) {
  if (freq <= 0) freq = 10000000LL;
  return (counter / freq) * 10000000LL + (counter % freq) * 10000000LL / freq;
}

inline int64_t Qpc100ns() {
  static const int64_t freq = [] {
    LARGE_INTEGER f{};
    QueryPerformanceFrequency(&f);
    return f.QuadPart ? f.QuadPart : 10000000LL;
  }();
  LARGE_INTEGER c{};
  QueryPerformanceCounter(&c);
  return Qpc100nsFrom(c.QuadPart, freq);
}

#endif  // RUNNER_RECORD_CLOCK_H_
