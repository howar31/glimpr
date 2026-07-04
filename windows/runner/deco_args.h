#ifndef RUNNER_DECO_ARGS_H_
#define RUNNER_DECO_ARGS_H_

#include <flutter/encodable_value.h>

#include <cstdint>

#include "channel_args.h"
#include "decoration.h"

// Decode a Dart decoration spec map into deco::DecoSpec. Shared by the direct
// capture and encode channels; kept out of channel_args.h so hosts that never
// decorate do not pull the capture/D3D headers in.
namespace chanarg {

inline deco::DecoSpec ParseDecoSpec(const flutter::EncodableMap& m) {
  deco::DecoSpec s;
  s.margin = GetDouble(m, "margin", 0);
  s.cornerRadius = GetDouble(m, "cornerRadius", 0);
  s.shadowBlur = GetDouble(m, "shadowBlur", 0);
  s.shadowDx = GetDouble(m, "shadowDx", 0);
  s.shadowDy = GetDouble(m, "shadowDy", 0);
  if (auto c = GetInt64(m, "shadowColor")) s.shadowArgb = static_cast<uint32_t>(*c);
  if (auto f = GetInt64(m, "fill")) s.fillArgb = static_cast<uint32_t>(*f);
  s.shapeFromAlpha = GetBool(m, "shapeFromAlpha", false);
  return s;
}

}  // namespace chanarg

#endif  // RUNNER_DECO_ARGS_H_
