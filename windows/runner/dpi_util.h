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

#ifndef WM_DPICHANGED_BEFOREPARENT
#define WM_DPICHANGED_BEFOREPARENT 0x02E2
#endif

// Make a reparented Flutter view adopt its host window's DPI. The embedder
// creates the view as a HWND_MESSAGE child, seeds its cached DPI from the
// PRIMARY monitor, and refreshes it only on WM_DPICHANGED_BEFOREPARENT, which
// Windows sends solely while a top-level window's DPI CHANGES. A host created
// directly on a monitor of another scale never changes DPI, so the view kept
// the primary scale after SetParent: pointer + layout ran at the wrong ratio
// (region select offset on a 100% display next to a 150% primary). Sending
// the message makes the view re-read GetDpiForWindow (now the host monitor's),
// and the explicit WM_SIZE re-sends window metrics, which the embedder only
// does on a resize. [width]/[height] = the view's current physical size.
inline void SyncFlutterViewDpi(HWND view, int width, int height) {
  if (!view) return;
  SendMessage(view, WM_DPICHANGED_BEFOREPARENT, 0, 0);
  SendMessage(view, WM_SIZE, SIZE_RESTORED, MAKELPARAM(width, height));
}

#endif  // RUNNER_DPI_UTIL_H_
