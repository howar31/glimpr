#ifndef RUNNER_DPI_UTIL_H_
#define RUNNER_DPI_UTIL_H_

#include <windows.h>

#include <shellscalingapi.h>

// Effective-DPI scale of a monitor (1.0 = 96 dpi); falls back to 1.0 when the
// query fails. Shared by every surface that maps logical <-> physical pixels.
inline double MonitorScale(HMONITOR mon) {
  UINT dpi_x = 96, dpi_y = 96;
  if (FAILED(GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y))) {
    dpi_x = 96;
  }
  return dpi_x / 96.0;
}

#endif  // RUNNER_DPI_UTIL_H_
