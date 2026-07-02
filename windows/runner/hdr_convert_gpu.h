#ifndef RUNNER_HDR_CONVERT_GPU_H_
#define RUNNER_HDR_CONVERT_GPU_H_

#include <d3d11.h>
#include <windows.h>

#include <cstdint>

// GPU colour conversion for the recorder's CONTINUOUS paths (a CPU per-pixel
// convert at 30 fps full-res would contend with the encoder). Two compute
// passes over the WGC fp16 scRGB frame:
//   - ToBgra: SDR tone-map (same math as hdr_util's LUT: scale by SDR white,
//     clip highlights, sRGB-encode) into an RGBA8 texture whose BYTE layout is
//     BGRA (the shader writes swizzled), so the existing RGB32 readback +
//     encode path consumes it unchanged.
//   - ToP010 (HDR10 recording): scRGB -> BT.2020 -> PQ -> 10-bit limited-range
//     YCbCr, written as separate Y (R16_UINT) + interleaved UV (R16G16_UINT,
//     half res) planes, crop applied in-shader. The caller reads both back and
//     packs a standard P010 buffer.
//
// Not thread-safe: the caller serializes access (the recorder's readback lock)
// because the D3D11 immediate context is not thread-safe.
class HdrConverter {
 public:
  HdrConverter() = default;
  ~HdrConverter() { ReleaseAll(); }
  HdrConverter(const HdrConverter&) = delete;
  HdrConverter& operator=(const HdrConverter&) = delete;

  // Compiles the shaders on |device|. False on failure (caller falls back).
  bool Init(ID3D11Device* device, ID3D11DeviceContext* context);

  // fp16 scRGB frame -> tone-mapped SDR frame (RGBA8 texture, BGRA byte
  // order). Returned texture is owned by the converter and valid until the
  // next call. nullptr on failure.
  ID3D11Texture2D* ToBgra(ID3D11Texture2D* f16_src, float sdr_white_nits);

  // fp16 scRGB frame -> P010 planes for the crop window [crop_x, crop_y,
  // cap_w x cap_h] (all in source pixels; cap_w/cap_h even). On success the
  // two STAGING textures are mapped-ready: |y_staging| cap_w x cap_h R16_UINT,
  // |uv_staging| cap_w/2 x cap_h/2 R16G16_UINT. False on failure.
  bool ToP010(ID3D11Texture2D* f16_src, uint32_t crop_x, uint32_t crop_y,
              uint32_t cap_w, uint32_t cap_h,
              ID3D11Texture2D** y_staging, ID3D11Texture2D** uv_staging);

 private:
  bool EnsureSrcCopy(ID3D11Texture2D* f16_src);

  ID3D11Device* device_ = nullptr;          // not owned
  ID3D11DeviceContext* context_ = nullptr;  // not owned

  // Shaders + params.
  ID3D11ComputeShader* cs_bgra_ = nullptr;
  ID3D11ComputeShader* cs_p010_y_ = nullptr;
  ID3D11ComputeShader* cs_p010_uv_ = nullptr;
  ID3D11Buffer* params_ = nullptr;

  // SRV-able copy of the WGC frame (WGC surfaces lack SHADER_RESOURCE bind).
  ID3D11Texture2D* src_copy_ = nullptr;
  ID3D11ShaderResourceView* src_srv_ = nullptr;
  uint32_t src_w_ = 0, src_h_ = 0;

  // ToBgra output.
  ID3D11Texture2D* bgra_tex_ = nullptr;
  ID3D11UnorderedAccessView* bgra_uav_ = nullptr;
  uint32_t bgra_w_ = 0, bgra_h_ = 0;

  // ToP010 outputs (default-usage + staging pairs).
  ID3D11Texture2D* y_tex_ = nullptr;
  ID3D11UnorderedAccessView* y_uav_ = nullptr;
  ID3D11Texture2D* y_staging_ = nullptr;
  ID3D11Texture2D* uv_tex_ = nullptr;
  ID3D11UnorderedAccessView* uv_uav_ = nullptr;
  ID3D11Texture2D* uv_staging_ = nullptr;
  uint32_t p010_w_ = 0, p010_h_ = 0;

  void ReleaseAll();

 public:
  // Explicit teardown (raw COM pointers; called by the destructor path of the
  // owner before device release).
  void Shutdown() { ReleaseAll(); }
};

#endif  // RUNNER_HDR_CONVERT_GPU_H_
