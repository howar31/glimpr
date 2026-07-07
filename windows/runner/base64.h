#ifndef RUNNER_BASE64_H_
#define RUNNER_BASE64_H_

#include <cstdint>
#include <string>

// Standard base64 encode/decode over raw byte strings. The record worker's
// output path is base64'd into an argv token so a path with spaces or non-ASCII
// bytes needs no command-line quoting (recorder_client encodes, record_worker
// decodes). Header-only + inline so both translation units share one copy.
namespace b64 {

inline std::string Encode(const std::string& in) {
  static const char* T =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  size_t i = 0;
  while (i + 3 <= in.size()) {
    uint32_t n = (uint32_t)(uint8_t)in[i] << 16 |
                 (uint32_t)(uint8_t)in[i + 1] << 8 | (uint8_t)in[i + 2];
    out += T[(n >> 18) & 63];
    out += T[(n >> 12) & 63];
    out += T[(n >> 6) & 63];
    out += T[n & 63];
    i += 3;
  }
  if (i + 1 == in.size()) {
    uint32_t n = (uint32_t)(uint8_t)in[i] << 16;
    out += T[(n >> 18) & 63];
    out += T[(n >> 12) & 63];
    out += "==";
  } else if (i + 2 == in.size()) {
    uint32_t n =
        (uint32_t)(uint8_t)in[i] << 16 | (uint32_t)(uint8_t)in[i + 1] << 8;
    out += T[(n >> 18) & 63];
    out += T[(n >> 12) & 63];
    out += T[(n >> 6) & 63];
    out += '=';
  }
  return out;
}

inline std::string Decode(const std::string& in) {
  auto val = [](char c) -> int {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
  };
  std::string out;
  int buf = 0, bits = 0;
  for (char c : in) {
    if (c == '=') break;
    int v = val(c);
    if (v < 0) continue;
    buf = (buf << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out += static_cast<char>((buf >> bits) & 0xFF);
    }
  }
  return out;
}

}  // namespace b64

#endif  // RUNNER_BASE64_H_
