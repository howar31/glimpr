#ifndef RUNNER_WAV_PARSE_H_
#define RUNNER_WAV_PARSE_H_

#include <windows.h>

#include <cstdint>
#include <cstring>

// Minimal RIFF/WAVE chunk walk: locates the "fmt " and "data" chunks of an
// in-memory WAV so the sound channel can feed raw cue bytes to XAudio2. Returns
// false on a malformed / non-PCM / truncated buffer. Header-only + inline so
// the channel and its tests share one definition.
namespace wavfmt {

inline bool ParseWav(const uint8_t* d, size_t n, WAVEFORMATEX& fmt,
                     const uint8_t*& pcm, uint32_t& pcm_len) {
  if (n < 12 || std::memcmp(d, "RIFF", 4) != 0 ||
      std::memcmp(d + 8, "WAVE", 4) != 0) {
    return false;
  }
  bool have_fmt = false, have_data = false;
  size_t pos = 12;
  while (pos + 8 <= n) {
    char id[4];
    std::memcpy(id, d + pos, 4);
    uint32_t sz = 0;
    std::memcpy(&sz, d + pos + 4, 4);
    const size_t body = pos + 8;
    if (body + sz > n) break;
    if (std::memcmp(id, "fmt ", 4) == 0 && sz >= 16) {
      std::memset(&fmt, 0, sizeof(fmt));
      const size_t copy = sz < sizeof(WAVEFORMATEX) ? sz : sizeof(WAVEFORMATEX);
      std::memcpy(&fmt, d + body, copy);
      // A 16-byte PCM header carries no cbSize field; force it to 0.
      if (sz < sizeof(WAVEFORMATEX)) fmt.cbSize = 0;
      have_fmt = true;
    } else if (std::memcmp(id, "data", 4) == 0) {
      pcm = d + body;
      pcm_len = sz;
      have_data = true;
    }
    pos = body + sz + (sz & 1);  // chunks are word-aligned
    if (have_fmt && have_data) break;
  }
  return have_fmt && have_data && pcm_len > 0;
}

}  // namespace wavfmt

#endif  // RUNNER_WAV_PARSE_H_
