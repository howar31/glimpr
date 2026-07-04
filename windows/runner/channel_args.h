#ifndef RUNNER_CHANNEL_ARGS_H_
#define RUNNER_CHANNEL_ARGS_H_

#include <flutter/encodable_value.h>

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

// Shared readers for flutter::EncodableMap method-call arguments, tolerant of
// the int32/int64 split the standard codec produces. Channel hosts pull these
// in with `using namespace chanarg;` so call sites stay unqualified.
namespace chanarg {

inline const flutter::EncodableValue* Find(const flutter::EncodableMap& map,
                                           const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  return it == map.end() ? nullptr : &it->second;
}

inline bool HasKey(const flutter::EncodableMap& map, const char* key) {
  return Find(map, key) != nullptr;
}

inline bool GetBool(const flutter::EncodableMap& map, const char* key,
                    bool dflt) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<bool>(v)) return *p;
  }
  return dflt;
}

inline int GetInt(const flutter::EncodableMap& map, const char* key,
                  int dflt) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<int32_t>(v)) return *p;
    if (auto p = std::get_if<int64_t>(v)) return static_cast<int>(*p);
  }
  return dflt;
}

inline std::optional<int64_t> GetInt64(const flutter::EncodableMap& map,
                                       const char* key) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<int32_t>(v)) return *p;
    if (auto p = std::get_if<int64_t>(v)) return *p;
  }
  return std::nullopt;
}

inline int64_t GetInt64(const flutter::EncodableMap& map, const char* key,
                        int64_t dflt) {
  return GetInt64(map, key).value_or(dflt);
}

inline double GetDouble(const flutter::EncodableMap& map, const char* key,
                        double dflt) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<double>(v)) return *p;
    if (auto p = std::get_if<int32_t>(v)) return static_cast<double>(*p);
    if (auto p = std::get_if<int64_t>(v)) return static_cast<double>(*p);
  }
  return dflt;
}

inline std::string GetString(const flutter::EncodableMap& map, const char* key,
                             const char* dflt = "") {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<std::string>(v)) return *p;
  }
  return dflt;
}

inline const std::vector<uint8_t>* GetBytes(const flutter::EncodableMap& map,
                                            const char* key) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<std::vector<uint8_t>>(v)) return p;
  }
  return nullptr;
}

inline const flutter::EncodableMap* GetMap(const flutter::EncodableMap& map,
                                           const char* key) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<flutter::EncodableMap>(v)) return p;
  }
  return nullptr;
}

}  // namespace chanarg

#endif  // RUNNER_CHANNEL_ARGS_H_
