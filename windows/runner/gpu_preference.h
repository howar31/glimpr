// Applies the user's persisted GPU preference (Settings > Advanced, Windows
// only) to a DartProject before its engines are created. Restart-effective
// for the main process (Settings + Image Editor engines share the project);
// the overlay host is spawned per screenshot session, so it follows the next
// session. On a single-GPU machine every choice resolves to that GPU, and an
// unknown value is "no preference" (the Dart default).
#ifndef RUNNER_GPU_PREFERENCE_H_
#define RUNNER_GPU_PREFERENCE_H_

#include <flutter/dart_project.h>

#include "prefs_probe.h"

namespace prefs {

inline flutter::GpuPreference ToFlutter(GpuChoice choice) {
  switch (choice) {
    case GpuChoice::kLowPower:
      return flutter::GpuPreference::LowPowerPreference;
    case GpuChoice::kHighPerformance:
      return flutter::GpuPreference::HighPerformancePreference;
    case GpuChoice::kSystem:
    default:
      return flutter::GpuPreference::NoPreference;
  }
}

inline void ApplyGpuPreference(flutter::DartProject* project) {
  project->set_gpu_preference(
      ToFlutter(GpuChoiceFromWire(ReadPrefsString("gpu_preference"))));
}

}  // namespace prefs

#endif  // RUNNER_GPU_PREFERENCE_H_
