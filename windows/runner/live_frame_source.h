#ifndef RUNNER_LIVE_FRAME_SOURCE_H_
#define RUNNER_LIVE_FRAME_SOURCE_H_

#include <windows.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <vector>

// Live pixels for the record-select loupe -- the Windows analogue of the macOS
// LiveFrameSource. A CONTINUOUS Windows.Graphics.Capture stream of one monitor
// that keeps only the LATEST frame on a staging texture. The transparent
// record-select overlay shows the real desktop through itself, so the loupe has
// no frozen image to read (unlike a screenshot); it samples this live stream
// instead. The overlay windows are SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)
// so this capture sees the TRUE desktop, not the dim veil. Lives only while a
// live-select session is up (OverlayManager owns one per display).
class LiveFrameSource {
 public:
  LiveFrameSource();
  ~LiveFrameSource();
  LiveFrameSource(const LiveFrameSource&) = delete;
  LiveFrameSource& operator=(const LiveFrameSource&) = delete;

  // Begin capturing [monitor]. Returns false on setup failure (the loupe just
  // stays empty; selection still works).
  bool Start(HMONITOR monitor);
  void Stop();

  // A span x span RGBA8888 patch centred on the display-local NATIVE pixel
  // (center_x, center_y) -- row-major, ready for Dart decodeImageFromPixels;
  // nullopt before the first frame. Out-of-bounds cells stay transparent.
  std::optional<std::vector<uint8_t>> Sample(int center_x, int center_y,
                                             int span);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_LIVE_FRAME_SOURCE_H_
