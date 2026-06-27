#ifndef RUNNER_RECORD_GIF_H_
#define RUNNER_RECORD_GIF_H_

#include <windows.h>

#include <cstdint>
#include <memory>
#include <string>

// Incremental animated-GIF encoder (WIC) for the recording GIF format -- the
// analogue of the macOS GifSink (ImageIO). Frames are BGRA8888 (top-down),
// downscaled to a fixed long-side ceiling, written one at a time with a per-frame
// delay; the container loops forever. No audio. One GifSink per recording, driven
// from the recorder's single encoder thread.
class GifSink {
 public:
  GifSink();
  ~GifSink();
  GifSink(const GifSink&) = delete;
  GifSink& operator=(const GifSink&) = delete;

  // Open the output file. |max_long_side| caps the longest dimension (px).
  bool Open(const std::wstring& path, uint32_t max_long_side);
  // Append one BGRA8888 top-down frame (stride = width*4) with |delay_cs|
  // hundredths of a second. Returns false on a fatal encode error.
  bool AddFrame(const uint8_t* bgra, uint32_t width, uint32_t height,
                uint32_t stride, uint32_t delay_cs);
  // Finalize the file.
  bool Finish();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
  uint32_t max_long_side_ = 1024;
};

#endif  // RUNNER_RECORD_GIF_H_
