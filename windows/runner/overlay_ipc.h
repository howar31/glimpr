#ifndef RUNNER_OVERLAY_IPC_H_
#define RUNNER_OVERLAY_IPC_H_

#include <string>

#include "base64.h"

// Line codec for the pipe between the main process and the overlay host child
// (glimpr.exe --overlay-host). One message per newline-terminated ASCII line:
//
//   VERB[ SP method[ SP base64(payload)]]
//
// The payload is opaque bytes (a StandardMessageCodec-encoded argument value,
// or a plain label), base64'd so arbitrary UTF-8 and binary survive the text
// framing. Header-only and free of Flutter / Win32 includes so the native unit
// tests can cover it.
//
// Child -> main: READY, ACK (a BEGIN was handled), CALL <method> [payload],
// PERF mark <label-as-payload>, BYE.
// Main -> child: BEGIN <pin_only> <live_select>, RSHOTKEY.
namespace oipc {

struct Message {
  std::string verb;
  std::string method;
  std::string payload;  // decoded bytes
  bool ok = false;
};

inline bool IsAlpha(const std::string& s) {
  if (s.empty()) return false;
  for (char c : s) {
    if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) return false;
  }
  return true;
}

inline bool IsBase64(const std::string& s) {
  if (s.empty() || s.size() % 4 != 0) return false;
  for (char c : s) {
    const bool valid = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                       (c >= '0' && c <= '9') || c == '+' || c == '/' ||
                       c == '=';
    if (!valid) return false;
  }
  return true;
}

// No trailing newline; the writer appends it.
inline std::string Format(const std::string& verb,
                          const std::string& method = "",
                          const std::string& payload = "") {
  std::string line = verb;
  if (!method.empty()) {
    line += ' ';
    line += method;
    if (!payload.empty()) {
      line += ' ';
      line += b64::Encode(payload);
    }
  }
  return line;
}

inline Message Parse(const std::string& raw) {
  Message m;
  std::string line = raw;
  while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) {
    line.pop_back();
  }
  const size_t a = line.find(' ');
  m.verb = line.substr(0, a);
  if (!IsAlpha(m.verb)) return m;
  if (a == std::string::npos) {
    // A bare verb. CALL and PERF need more than that.
    m.ok = (m.verb != "CALL" && m.verb != "PERF" && m.verb != "BEGIN");
    return m;
  }
  const size_t b = line.find(' ', a + 1);
  m.method = line.substr(a + 1, b == std::string::npos ? b : b - a - 1);
  if (m.method.empty()) return m;
  if (m.verb == "BEGIN") {
    // BEGIN carries two 0/1 flags in the method + payload slots, not base64.
    if (b == std::string::npos) return m;
    m.payload = line.substr(b + 1);
    m.ok = (m.method == "0" || m.method == "1") &&
           (m.payload == "0" || m.payload == "1");
    return m;
  }
  if (!IsAlpha(m.method)) return m;
  if (b != std::string::npos) {
    const std::string enc = line.substr(b + 1);
    if (!IsBase64(enc)) return m;
    m.payload = b64::Decode(enc);
  }
  m.ok = true;
  return m;
}

inline std::string FormatBegin(bool pin_only, bool live_select) {
  return std::string("BEGIN ") + (pin_only ? "1" : "0") + " " +
         (live_select ? "1" : "0");
}

inline bool ParseBegin(const Message& m, bool* pin_only, bool* live_select) {
  if (!m.ok || m.verb != "BEGIN") return false;
  *pin_only = (m.method == "1");
  *live_select = (m.payload == "1");
  return true;
}

}  // namespace oipc

#endif  // RUNNER_OVERLAY_IPC_H_
