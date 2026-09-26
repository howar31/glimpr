#include "diagnostics.h"

#include <dxgi1_6.h>
#include <shellscalingapi.h>
#include <windows.h>

#include <cstdio>
#include <map>
#include <string>
#include <vector>

#include "hdr_util.h"
#include "utils.h"

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace diag {

namespace {

// "Windows 11 24H2 (10.0.26100.4351)": kernel version via RtlGetVersion (the
// documented GetVersionEx lies past 8.1 without a manifest), the marketing
// name + UBR from the CurrentVersion registry key.
std::string OsString() {
  using RtlGetVersionFn = LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
  RTL_OSVERSIONINFOW v{};
  v.dwOSVersionInfoSize = sizeof(v);
  if (HMODULE ntdll = GetModuleHandleW(L"ntdll.dll")) {
    if (auto fn = reinterpret_cast<RtlGetVersionFn>(
            GetProcAddress(ntdll, "RtlGetVersion"))) {
      fn(&v);
    }
  }
  DWORD ubr = 0;
  wchar_t display_version[64] = L"";
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_LOCAL_MACHINE,
                    L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion", 0,
                    KEY_READ, &key) == ERROR_SUCCESS) {
    DWORD size = sizeof(ubr);
    RegQueryValueExW(key, L"UBR", nullptr, nullptr,
                     reinterpret_cast<LPBYTE>(&ubr), &size);
    size = sizeof(display_version);
    if (RegQueryValueExW(key, L"DisplayVersion", nullptr, nullptr,
                         reinterpret_cast<LPBYTE>(display_version),
                         &size) != ERROR_SUCCESS) {
      display_version[0] = L'\0';
    }
    RegCloseKey(key);
  }
  const char* name = v.dwBuildNumber >= 22000 ? "Windows 11" : "Windows 10";
  char out[128];
  const std::string dv = Utf8FromUtf16(display_version);
  sprintf_s(out, "%s%s%s (%lu.%lu.%lu.%lu)", name, dv.empty() ? "" : " ",
            dv.c_str(), v.dwMajorVersion, v.dwMinorVersion, v.dwBuildNumber,
            ubr);
  return out;
}

std::string ArchString() {
  SYSTEM_INFO si{};
  GetNativeSystemInfo(&si);
  switch (si.wProcessorArchitecture) {
    case PROCESSOR_ARCHITECTURE_AMD64: return "x64";
    case PROCESSOR_ARCHITECTURE_ARM64: return "arm64";
    case PROCESSOR_ARCHITECTURE_INTEL: return "x86";
    default: return "";
  }
}

// GPU adapters (software renderers skipped) + which adapter drives each
// monitor, from one DXGI walk.
struct AdapterInfo {
  std::vector<std::string> gpus;
  std::map<HMONITOR, std::string> adapter_for_monitor;
};

AdapterInfo WalkAdapters() {
  AdapterInfo info;
  IDXGIFactory1* f = nullptr;
  if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1),
                                reinterpret_cast<void**>(&f)))) {
    return info;
  }
  for (UINT a = 0;; ++a) {
    IDXGIAdapter1* adapter = nullptr;
    if (f->EnumAdapters1(a, &adapter) != S_OK) break;
    DXGI_ADAPTER_DESC1 ad{};
    std::string name;
    if (SUCCEEDED(adapter->GetDesc1(&ad)) &&
        !(ad.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) {
      name = Utf8FromUtf16(ad.Description);
      info.gpus.push_back(name);
    }
    for (UINT o = 0;; ++o) {
      IDXGIOutput* output = nullptr;
      if (adapter->EnumOutputs(o, &output) != S_OK) break;
      DXGI_OUTPUT_DESC od{};
      if (SUCCEEDED(output->GetDesc(&od)) && !name.empty()) {
        info.adapter_for_monitor[od.Monitor] = name;
      }
      output->Release();
    }
    adapter->Release();
  }
  f->Release();
  return info;
}

// The monitor's friendly name (EDID) via DisplayConfig, matched to the GDI
// source name; empty when unavailable.
std::string FriendlyName(const wchar_t* gdi_name) {
  UINT32 num_paths = 0, num_modes = 0;
  if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &num_paths,
                                  &num_modes) != ERROR_SUCCESS) {
    return "";
  }
  std::vector<DISPLAYCONFIG_PATH_INFO> paths(num_paths);
  std::vector<DISPLAYCONFIG_MODE_INFO> modes(num_modes);
  if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &num_paths, paths.data(),
                         &num_modes, modes.data(), nullptr) != ERROR_SUCCESS) {
    return "";
  }
  for (UINT32 i = 0; i < num_paths; ++i) {
    DISPLAYCONFIG_SOURCE_DEVICE_NAME sn{};
    sn.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
    sn.header.size = sizeof(sn);
    sn.header.adapterId = paths[i].sourceInfo.adapterId;
    sn.header.id = paths[i].sourceInfo.id;
    if (DisplayConfigGetDeviceInfo(&sn.header) != ERROR_SUCCESS) continue;
    if (wcscmp(sn.viewGdiDeviceName, gdi_name) != 0) continue;
    DISPLAYCONFIG_TARGET_DEVICE_NAME tn{};
    tn.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
    tn.header.size = sizeof(tn);
    tn.header.adapterId = paths[i].targetInfo.adapterId;
    tn.header.id = paths[i].targetInfo.id;
    if (DisplayConfigGetDeviceInfo(&tn.header) != ERROR_SUCCESS) return "";
    return Utf8FromUtf16(tn.monitorFriendlyDeviceName);
  }
  return "";
}

struct MonitorList {
  std::vector<HMONITOR> monitors;
};

BOOL CALLBACK CollectMonitor(HMONITOR m, HDC, LPRECT, LPARAM lp) {
  reinterpret_cast<MonitorList*>(lp)->monitors.push_back(m);
  return TRUE;
}

EncodableMap DisplayEntry(HMONITOR m, const AdapterInfo& adapters) {
  EncodableMap d;
  MONITORINFOEXW mi{};
  mi.cbSize = sizeof(mi);
  if (GetMonitorInfoW(m, &mi)) {
    d[EncodableValue("width")] =
        EncodableValue(static_cast<int>(mi.rcMonitor.right - mi.rcMonitor.left));
    d[EncodableValue("height")] =
        EncodableValue(static_cast<int>(mi.rcMonitor.bottom - mi.rcMonitor.top));
    d[EncodableValue("primary")] =
        EncodableValue((mi.dwFlags & MONITORINFOF_PRIMARY) != 0);
    std::string name = FriendlyName(mi.szDevice);
    if (name.empty()) name = Utf8FromUtf16(mi.szDevice);
    d[EncodableValue("name")] = EncodableValue(name);
  }
  UINT dpi_x = 96, dpi_y = 96;
  if (SUCCEEDED(GetDpiForMonitor(m, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y))) {
    d[EncodableValue("scale")] = EncodableValue(dpi_x / 96.0);
  }
  const hdr::MonitorHdrInfo h = hdr::QueryMonitorHdr(m);
  d[EncodableValue("hdr")] = EncodableValue(h.hdr);
  d[EncodableValue("color_space")] = EncodableValue(h.color_space);
  d[EncodableValue("bits_per_color")] = EncodableValue(h.bits_per_color);
  if (h.hdr) {
    d[EncodableValue("sdr_white_nits")] =
        EncodableValue(static_cast<double>(h.sdr_white_nits));
    d[EncodableValue("max_nits")] =
        EncodableValue(static_cast<double>(h.max_nits));
  }
  auto it = adapters.adapter_for_monitor.find(m);
  if (it != adapters.adapter_for_monitor.end()) {
    d[EncodableValue("adapter")] = EncodableValue(it->second);
  }
  return d;
}

}  // namespace

EncodableValue Collect() {
  EncodableMap out;
  out[EncodableValue("os")] = EncodableValue(OsString());
  out[EncodableValue("arch")] = EncodableValue(ArchString());
  const AdapterInfo adapters = WalkAdapters();
  EncodableList gpus;
  for (const auto& g : adapters.gpus) gpus.push_back(EncodableValue(g));
  out[EncodableValue("gpus")] = EncodableValue(gpus);
  MonitorList list;
  EnumDisplayMonitors(nullptr, nullptr, CollectMonitor,
                      reinterpret_cast<LPARAM>(&list));
  EncodableList displays;
  for (HMONITOR m : list.monitors) {
    displays.push_back(EncodableValue(DisplayEntry(m, adapters)));
  }
  out[EncodableValue("displays")] = EncodableValue(displays);
  return EncodableValue(out);
}

}  // namespace diag
