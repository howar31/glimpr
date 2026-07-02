#include "hdr_convert_gpu.h"

#include <d3dcompiler.h>

#include <cstring>

namespace {

// Shared HLSL: PQ + BT.709->BT.2020 + the SDR tone-map, mirroring hdr_util's
// CPU LUT math (keep in sync).
const char kShaderSource[] = R"hlsl(
Texture2D<float4> src : register(t0);
cbuffer Params : register(b0) {
  float sdr_scale;   // 80 / sdr_white_nits
  uint crop_x;
  uint crop_y;
  uint pad0;
}

float SrgbEncode(float c) {
  return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(abs(c), 1.0 / 2.4) - 0.055;
}

// scRGB linear (BT.709, 1.0 == 80 nits) -> PQ-encoded BT.2020 [0,1].
float3 ScrgbToPq2020(float3 rgb709) {
  // BT.709 -> BT.2020 primaries (linear light).
  float3 c;
  c.r = dot(float3(0.627404, 0.329283, 0.043313), rgb709);
  c.g = dot(float3(0.069097, 0.919540, 0.011362), rgb709);
  c.b = dot(float3(0.016391, 0.088013, 0.895595), rgb709);
  // Display light: 1.0 scRGB == 80 nits; PQ domain is [0,1] == [0,10000] nits.
  float3 y = saturate(c * (80.0 / 10000.0));
  const float m1 = 0.1593017578125;
  const float m2 = 78.84375;
  const float c1 = 0.8359375;
  const float c2 = 18.8515625;
  const float c3 = 18.6875;
  float3 ym = pow(y, m1);
  return pow((c1 + c2 * ym) / (1.0 + c3 * ym), m2);
}

// ---- SDR tone-map: fp16 scRGB -> RGBA8 texture in BGRA byte order ----------
RWTexture2D<unorm float4> dst_bgra : register(u0);

[numthreads(8, 8, 1)]
void MainBgra(uint3 id : SV_DispatchThreadID) {
  uint w, h;
  dst_bgra.GetDimensions(w, h);
  if (id.x >= w || id.y >= h) return;
  float3 c = saturate(src[id.xy].rgb * sdr_scale);
  // Swizzled write: RGBA8 memory bytes become B,G,R,255 == RGB32/BGRA.
  dst_bgra[id.xy] =
      float4(SrgbEncode(c.b), SrgbEncode(c.g), SrgbEncode(c.r), 1.0);
}

// ---- HDR10: Y plane (10-bit limited range in P010 high bits) ---------------
RWTexture2D<uint> dst_y : register(u0);

[numthreads(8, 8, 1)]
void MainY(uint3 id : SV_DispatchThreadID) {
  uint w, h;
  dst_y.GetDimensions(w, h);
  if (id.x >= w || id.y >= h) return;
  float3 e = ScrgbToPq2020(src[uint2(id.x + crop_x, id.y + crop_y)].rgb);
  float yp = dot(float3(0.2627, 0.6780, 0.0593), e);
  uint dy = (uint)round(clamp(876.0 * yp + 64.0, 64.0, 940.0));
  dst_y[id.xy] = dy << 6;
}

// ---- HDR10: interleaved UV plane (half res, 2x2 chroma average) ------------
RWTexture2D<uint2> dst_uv : register(u0);

[numthreads(8, 8, 1)]
void MainUv(uint3 id : SV_DispatchThreadID) {
  uint w, h;
  dst_uv.GetDimensions(w, h);
  if (id.x >= w || id.y >= h) return;
  uint2 base = uint2(id.x * 2 + crop_x, id.y * 2 + crop_y);
  float cb = 0.0;
  float cr = 0.0;
  [unroll]
  for (uint dy = 0; dy < 2; ++dy) {
    [unroll]
    for (uint dx = 0; dx < 2; ++dx) {
      float3 e = ScrgbToPq2020(src[base + uint2(dx, dy)].rgb);
      float yp = dot(float3(0.2627, 0.6780, 0.0593), e);
      cb += (e.b - yp) / 1.8814;
      cr += (e.r - yp) / 1.4746;
    }
  }
  cb *= 0.25;
  cr *= 0.25;
  uint du = (uint)round(clamp(896.0 * cb + 512.0, 64.0, 960.0));
  uint dv = (uint)round(clamp(896.0 * cr + 512.0, 64.0, 960.0));
  dst_uv[id.xy] = uint2(du << 6, dv << 6);
}
)hlsl";

ID3D11ComputeShader* CompileCs(ID3D11Device* device, const char* entry) {
  ID3DBlob* blob = nullptr;
  ID3DBlob* errors = nullptr;
  HRESULT hr = D3DCompile(kShaderSource, sizeof(kShaderSource) - 1, nullptr,
                          nullptr, nullptr, entry, "cs_5_0",
                          D3DCOMPILE_OPTIMIZATION_LEVEL2, 0, &blob, &errors);
  if (errors) errors->Release();
  if (FAILED(hr) || !blob) return nullptr;
  ID3D11ComputeShader* cs = nullptr;
  hr = device->CreateComputeShader(blob->GetBufferPointer(),
                                   blob->GetBufferSize(), nullptr, &cs);
  blob->Release();
  return SUCCEEDED(hr) ? cs : nullptr;
}

struct ParamsCb {
  float sdr_scale;
  uint32_t crop_x;
  uint32_t crop_y;
  uint32_t pad0;
};

template <typename T>
void SafeRelease(T** p) {
  if (*p) {
    (*p)->Release();
    *p = nullptr;
  }
}

}  // namespace

bool HdrConverter::Init(ID3D11Device* device, ID3D11DeviceContext* context) {
  device_ = device;
  context_ = context;
  cs_bgra_ = CompileCs(device, "MainBgra");
  cs_p010_y_ = CompileCs(device, "MainY");
  cs_p010_uv_ = CompileCs(device, "MainUv");
  if (!cs_bgra_ || !cs_p010_y_ || !cs_p010_uv_) {
    ReleaseAll();
    return false;
  }
  D3D11_BUFFER_DESC bd{};
  bd.ByteWidth = sizeof(ParamsCb);
  bd.Usage = D3D11_USAGE_DYNAMIC;
  bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
  bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  if (FAILED(device_->CreateBuffer(&bd, nullptr, &params_))) {
    ReleaseAll();
    return false;
  }
  return true;
}

void HdrConverter::ReleaseAll() {
  SafeRelease(&cs_bgra_);
  SafeRelease(&cs_p010_y_);
  SafeRelease(&cs_p010_uv_);
  SafeRelease(&params_);
  SafeRelease(&src_srv_);
  SafeRelease(&src_copy_);
  SafeRelease(&bgra_uav_);
  SafeRelease(&bgra_tex_);
  SafeRelease(&y_uav_);
  SafeRelease(&y_tex_);
  SafeRelease(&y_staging_);
  SafeRelease(&uv_uav_);
  SafeRelease(&uv_tex_);
  SafeRelease(&uv_staging_);
  src_w_ = src_h_ = bgra_w_ = bgra_h_ = p010_w_ = p010_h_ = 0;
}

bool HdrConverter::EnsureSrcCopy(ID3D11Texture2D* f16_src) {
  D3D11_TEXTURE2D_DESC desc{};
  f16_src->GetDesc(&desc);
  if (!src_copy_ || src_w_ != desc.Width || src_h_ != desc.Height) {
    SafeRelease(&src_srv_);
    SafeRelease(&src_copy_);
    D3D11_TEXTURE2D_DESC sd{};
    sd.Width = desc.Width;
    sd.Height = desc.Height;
    sd.MipLevels = 1;
    sd.ArraySize = 1;
    sd.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
    sd.SampleDesc.Count = 1;
    sd.Usage = D3D11_USAGE_DEFAULT;
    sd.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    if (FAILED(device_->CreateTexture2D(&sd, nullptr, &src_copy_))) {
      return false;
    }
    if (FAILED(device_->CreateShaderResourceView(src_copy_, nullptr,
                                                 &src_srv_))) {
      SafeRelease(&src_copy_);
      return false;
    }
    src_w_ = desc.Width;
    src_h_ = desc.Height;
  }
  context_->CopyResource(src_copy_, f16_src);
  return true;
}

ID3D11Texture2D* HdrConverter::ToBgra(ID3D11Texture2D* f16_src,
                                      float sdr_white_nits) {
  if (!cs_bgra_ || !EnsureSrcCopy(f16_src)) return nullptr;
  if (!bgra_tex_ || bgra_w_ != src_w_ || bgra_h_ != src_h_) {
    SafeRelease(&bgra_uav_);
    SafeRelease(&bgra_tex_);
    D3D11_TEXTURE2D_DESC td{};
    td.Width = src_w_;
    td.Height = src_h_;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_UNORDERED_ACCESS;
    if (FAILED(device_->CreateTexture2D(&td, nullptr, &bgra_tex_))) {
      return nullptr;
    }
    if (FAILED(device_->CreateUnorderedAccessView(bgra_tex_, nullptr,
                                                  &bgra_uav_))) {
      SafeRelease(&bgra_tex_);
      return nullptr;
    }
    bgra_w_ = src_w_;
    bgra_h_ = src_h_;
  }

  D3D11_MAPPED_SUBRESOURCE mapped{};
  if (FAILED(context_->Map(params_, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) {
    return nullptr;
  }
  ParamsCb cb{};
  cb.sdr_scale =
      80.0f / (sdr_white_nits > 1.0f ? sdr_white_nits : 80.0f);
  std::memcpy(mapped.pData, &cb, sizeof(cb));
  context_->Unmap(params_, 0);

  context_->CSSetShader(cs_bgra_, nullptr, 0);
  context_->CSSetShaderResources(0, 1, &src_srv_);
  context_->CSSetUnorderedAccessViews(0, 1, &bgra_uav_, nullptr);
  context_->CSSetConstantBuffers(0, 1, &params_);
  context_->Dispatch((bgra_w_ + 7) / 8, (bgra_h_ + 7) / 8, 1);
  // Unbind so the texture is free for CopyResource.
  ID3D11UnorderedAccessView* null_uav = nullptr;
  ID3D11ShaderResourceView* null_srv = nullptr;
  context_->CSSetUnorderedAccessViews(0, 1, &null_uav, nullptr);
  context_->CSSetShaderResources(0, 1, &null_srv);
  return bgra_tex_;
}

bool HdrConverter::ToP010(ID3D11Texture2D* f16_src, uint32_t crop_x,
                          uint32_t crop_y, uint32_t cap_w, uint32_t cap_h,
                          ID3D11Texture2D** y_staging,
                          ID3D11Texture2D** uv_staging) {
  if (!cs_p010_y_ || !cs_p010_uv_ || cap_w < 2 || cap_h < 2) return false;
  if (!EnsureSrcCopy(f16_src)) return false;
  if (!y_tex_ || p010_w_ != cap_w || p010_h_ != cap_h) {
    SafeRelease(&y_uav_);
    SafeRelease(&y_tex_);
    SafeRelease(&y_staging_);
    SafeRelease(&uv_uav_);
    SafeRelease(&uv_tex_);
    SafeRelease(&uv_staging_);
    D3D11_TEXTURE2D_DESC td{};
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_UNORDERED_ACCESS;
    td.Width = cap_w;
    td.Height = cap_h;
    td.Format = DXGI_FORMAT_R16_UINT;
    if (FAILED(device_->CreateTexture2D(&td, nullptr, &y_tex_))) return false;
    if (FAILED(device_->CreateUnorderedAccessView(y_tex_, nullptr, &y_uav_))) {
      SafeRelease(&y_tex_);
      return false;
    }
    td.Width = cap_w / 2;
    td.Height = cap_h / 2;
    td.Format = DXGI_FORMAT_R16G16_UINT;
    if (FAILED(device_->CreateTexture2D(&td, nullptr, &uv_tex_))) {
      return false;
    }
    if (FAILED(
            device_->CreateUnorderedAccessView(uv_tex_, nullptr, &uv_uav_))) {
      SafeRelease(&uv_tex_);
      return false;
    }
    D3D11_TEXTURE2D_DESC sd{};
    sd.MipLevels = 1;
    sd.ArraySize = 1;
    sd.SampleDesc.Count = 1;
    sd.Usage = D3D11_USAGE_STAGING;
    sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    sd.Width = cap_w;
    sd.Height = cap_h;
    sd.Format = DXGI_FORMAT_R16_UINT;
    if (FAILED(device_->CreateTexture2D(&sd, nullptr, &y_staging_))) {
      return false;
    }
    sd.Width = cap_w / 2;
    sd.Height = cap_h / 2;
    sd.Format = DXGI_FORMAT_R16G16_UINT;
    if (FAILED(device_->CreateTexture2D(&sd, nullptr, &uv_staging_))) {
      return false;
    }
    p010_w_ = cap_w;
    p010_h_ = cap_h;
  }

  D3D11_MAPPED_SUBRESOURCE mapped{};
  if (FAILED(context_->Map(params_, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) {
    return false;
  }
  ParamsCb cb{};
  cb.crop_x = crop_x;
  cb.crop_y = crop_y;
  std::memcpy(mapped.pData, &cb, sizeof(cb));
  context_->Unmap(params_, 0);

  context_->CSSetShaderResources(0, 1, &src_srv_);
  context_->CSSetConstantBuffers(0, 1, &params_);
  context_->CSSetShader(cs_p010_y_, nullptr, 0);
  context_->CSSetUnorderedAccessViews(0, 1, &y_uav_, nullptr);
  context_->Dispatch((cap_w + 7) / 8, (cap_h + 7) / 8, 1);
  context_->CSSetShader(cs_p010_uv_, nullptr, 0);
  context_->CSSetUnorderedAccessViews(0, 1, &uv_uav_, nullptr);
  context_->Dispatch((cap_w / 2 + 7) / 8, (cap_h / 2 + 7) / 8, 1);
  ID3D11UnorderedAccessView* null_uav = nullptr;
  ID3D11ShaderResourceView* null_srv = nullptr;
  context_->CSSetUnorderedAccessViews(0, 1, &null_uav, nullptr);
  context_->CSSetShaderResources(0, 1, &null_srv);

  context_->CopyResource(y_staging_, y_tex_);
  context_->CopyResource(uv_staging_, uv_tex_);
  *y_staging = y_staging_;
  *uv_staging = uv_staging_;
  return true;
}
