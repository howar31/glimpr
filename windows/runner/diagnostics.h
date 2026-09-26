#ifndef RUNNER_DIAGNOSTICS_H_
#define RUNNER_DIAGNOSTICS_H_

#include <flutter/encodable_value.h>

// Settings > About > Report an issue: the environment snapshot (OS build,
// CPU architecture, GPU adapters, every display with its DPI scale and HDR
// state). Gathered ONLY when the report page opens; nothing here runs in the
// background. Keys are stable wire names rendered by lib/settings/diagnostics.dart.
namespace diag {

flutter::EncodableValue Collect();

}  // namespace diag

#endif  // RUNNER_DIAGNOSTICS_H_
