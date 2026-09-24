#include "editor_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <ole2.h>
#include <shellapi.h>

#include <flutter/generated_plugin_registrant.h>

#include <atomic>
#include <optional>
#include <utility>

#include "drop_filter.h"
#include "font_enum.h"
#include "perf_log.h"
#include "utils.h"
#include "win_reveal.h"

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {
// Editor window default content size + minimum (matching macOS Phase 5:
// 1280x720, min 1060x720).
constexpr int kDefaultW = 1280;
constexpr int kDefaultH = 720;
constexpr int kMinW = 1060;
constexpr int kMinH = 720;

std::unique_ptr<EncodableValue> StrArg(const std::string& s) {
  return std::make_unique<EncodableValue>(EncodableValue(s));
}

// OLE drop target for the editor window: vetoes non-image drags AT HOVER
// (DragEnter/DragOver answer DROPEFFECT_NONE -> the cursor shows "not
// allowed" and Drop never fires) -- the same timing as macOS's
// draggingEntered. WM_DROPFILES cannot veto at hover, hence OLE; it needs
// the OleInitialize'd platform thread (main.cpp).
class EditorDropTarget : public IDropTarget {
 public:
  explicit EditorDropTarget(EditorWindow* owner) : owner_(owner) {}
  virtual ~EditorDropTarget() = default;

  // IUnknown --
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) return E_POINTER;
    if (riid == IID_IUnknown || riid == IID_IDropTarget) {
      *ppv = static_cast<IDropTarget*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(++refs_);
  }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG n = static_cast<ULONG>(--refs_);
    if (n == 0) delete this;
    return n;
  }

  // IDropTarget --
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD, POINTL,
                                      DWORD* effect) override {
    accept_ = FirstImagePath(data).has_value();
    if (effect) *effect = accept_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD* effect) override {
    if (effect) *effect = accept_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragLeave() override {
    accept_ = false;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD, POINTL,
                                 DWORD* effect) override {
    const std::optional<std::string> path = FirstImagePath(data);
    if (effect) *effect = path ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    if (path && owner_) owner_->OpenWithPath(*path);
    accept_ = false;
    return S_OK;
  }

  // The owning window is going away; the target may outlive it briefly on the
  // OLE side.
  void Detach() { owner_ = nullptr; }

 private:
  // The first dragged file whose extension the editor supports (as UTF-8), or
  // nullopt. Mirrors macOS imageURL(_:): first supported file wins.
  static std::optional<std::string> FirstImagePath(IDataObject* data) {
    if (!data) return std::nullopt;
    FORMATETC fmt{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM medium{};
    if (FAILED(data->GetData(&fmt, &medium))) return std::nullopt;
    std::optional<std::string> out;
    if (auto* drop = static_cast<HDROP>(GlobalLock(medium.hGlobal))) {
      const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
      for (UINT i = 0; i < count && !out; ++i) {
        const UINT len = DragQueryFileW(drop, i, nullptr, 0);
        if (len == 0) continue;
        std::wstring path(len + 1, L'\0');
        if (DragQueryFileW(drop, i, path.data(), len + 1) == 0) continue;
        path.resize(len);
        if (dropfilter::IsEditorImagePath(path)) out = Utf8FromUtf16(path);
      }
      GlobalUnlock(medium.hGlobal);
    }
    ReleaseStgMedium(&medium);
    return out;
  }

  EditorWindow* owner_;
  std::atomic<long> refs_{1};
  bool accept_ = false;
};

}  // namespace

EditorWindow::EditorWindow(const flutter::DartProject& project,
                           EditorHostLink* link)
    : project_(project), link_(link) {}

EditorWindow::~EditorWindow() {}

void EditorWindow::WarmUp() { EnsureCreated(); }

void EditorWindow::EnsureCreated() {
  if (GetHandle()) return;  // already built (warm or lazy)
  // A sensible default position near the top-left; the window is movable.
  Win32Window::Point origin(80, 60);
  Win32Window::Size size(kDefaultW, kDefaultH);
  Create(L"Image Editor", origin, size);  // -> OnCreate builds the engine
  SetQuitOnClose(false);  // close hides; the host's exit gate ends the process
}

void EditorWindow::RevealEditor() {
  EnsureCreated();
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  if (shown_once_) {
    ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
    if (flutter_controller_) flutter_controller_->ForceRedraw();
    SetForegroundWindow(hwnd);
    link_->Shown();
    return;
  }
  // First reveal of this (cold) process: restore the previous host's
  // placement, then paint before showing so the user never sees a blank frame
  // or the unlocalised caption.
  if (placement_) {
    WINDOWPLACEMENT wp{};
    wp.length = sizeof(wp);
    wp.showCmd = SW_HIDE;
    wp.rcNormalPosition = {placement_->left, placement_->top,
                           placement_->right, placement_->bottom};
    SetWindowPlacement(hwnd, &wp);
  }
  const int show_cmd =
      (placement_ && placement_->show_cmd == 3) ? SW_SHOWMAXIMIZED : SW_SHOW;
  auto show = [this, hwnd, show_cmd]() {
    shown_once_ = true;
    ShowWindow(hwnd, show_cmd);
    SetForegroundWindow(hwnd);
    link_->Shown();
  };
  if (flutter_controller_) {
    flutter_controller_->engine()->SetNextFrameCallback(show);
    flutter_controller_->ForceRedraw();
  } else {
    show();
  }
}

void EditorWindow::CapturePlacement() {
  HWND hwnd = GetHandle();
  if (!hwnd || !shown_once_) return;
  WINDOWPLACEMENT wp{};
  wp.length = sizeof(wp);
  if (!GetWindowPlacement(hwnd, &wp)) return;
  eplace::Placement p;
  p.left = wp.rcNormalPosition.left;
  p.top = wp.rcNormalPosition.top;
  p.right = wp.rcNormalPosition.right;
  p.bottom = wp.rcNormalPosition.bottom;
  p.show_cmd = (wp.showCmd == SW_SHOWMAXIMIZED) ? 3 : 1;
  last_placement_ = p;
}

bool EditorWindow::GetPlacement(eplace::Placement* out) const {
  if (!last_placement_) return false;
  *out = *last_placement_;
  return true;
}

bool EditorWindow::IsHidden() const {
  HWND hwnd = const_cast<EditorWindow*>(this)->GetHandle();
  return !hwnd || !IsWindowVisible(hwnd);
}

void EditorWindow::OpenWithPath(const std::string& path) {
  RevealEditor();
  if (ready_) {
    InvokeLoadPath(path);
  } else {
    pending_path_ = path;  // flushed on editorReady
  }
}

void EditorWindow::LoadClipboard() {
  RevealEditor();
  if (ready_) {
    InvokeLoadClipboard();
  } else {
    pending_clipboard_ = true;
  }
}

void EditorWindow::ClearRecent() {
  if (editor_channel_) editor_channel_->InvokeMethod("clearRecent", nullptr);
}

void EditorWindow::RefreshRecent() {
  if (editor_channel_) editor_channel_->InvokeMethod("refreshRecent", nullptr);
}

void EditorWindow::FlushPending() {
  if (!ready_) return;
  if (pending_clipboard_) {
    pending_clipboard_ = false;
    InvokeLoadClipboard();
  }
  if (pending_path_) {
    const std::string p = *pending_path_;
    pending_path_.reset();
    InvokeLoadPath(p);
  }
}

void EditorWindow::InvokeLoadPath(const std::string& path) {
  if (editor_channel_) editor_channel_->InvokeMethod("loadPath", StrArg(path));
}

void EditorWindow::InvokeLoadClipboard() {
  if (editor_channel_) editor_channel_->InvokeMethod("loadClipboard", nullptr);
}

bool EditorWindow::OnCreate() {
  if (!Win32Window::OnCreate()) return false;

  RECT frame = GetClientArea();
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  auto* messenger = flutter_controller_->engine()->messenger();

  // This is the IMAGE-EDITOR engine: answer glimpr/role so main.dart mounts the
  // editor app, and host glimpr/imageEditor (the editor <-> native bridge).
  role_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "glimpr/role", &flutter::StandardMethodCodec::GetInstance());
  role_channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() == "getRole") {
          result->Success(EncodableValue("image-editor"));
        } else if (call.method_name() == "revealInExplorer") {
          if (const auto* a =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = a->find(flutter::EncodableValue(std::string("path")));
            if (it != a->end()) {
              if (const auto* p = std::get_if<std::string>(&it->second)) {
                RevealInExplorer(*p);
              }
            }
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  editor_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "glimpr/imageEditor",
      &flutter::StandardMethodCodec::GetInstance());
  editor_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const std::string& m = call.method_name();
        if (m == "editorReady") {
          ready_ = true;
          FlushPending();
          link_->Ready();
          result->Success();
        } else if (m == "hideEditor") {
          CapturePlacement();
          if (GetHandle()) ShowWindow(GetHandle(), SW_HIDE);
          result->Success();
          link_->Hidden();
        } else if (m == "setRecentImages") {
          // The tray "Open Recent" list lives in the main process.
          if (call.arguments()) link_->Call("setRecentImages", *call.arguments());
          result->Success();
        } else if (m == "pinImage") {
          // The editor's pin flow leg: the main process floats the file
          // centered (the path stays valid after this process exits).
          if (call.arguments()) link_->Call("pinImage", *call.arguments());
          result->Success();
        } else if (m == "setProcessing") {
          // Editor Done/export commit (true) / delivered (false): the main
          // process drives the tray's processing pulse; this side keeps the
          // flag so the exit gate never ends the process mid-export.
          if (const auto* a = std::get_if<EncodableMap>(call.arguments())) {
            auto it = a->find(EncodableValue(std::string("active")));
            if (it != a->end()) {
              if (const auto* b = std::get_if<bool>(&it->second)) {
                processing_ = *b;
              }
            }
          }
          if (call.arguments()) link_->Call("setProcessing", *call.arguments());
          result->Success();
        } else if (m == "perfMark") {
          // Dart-side perf marks (editor first-frame/open/export timing) land
          // on the same timeline as the native marks. Inert unless the
          // debugHooks gate is on.
          if (const auto* a = std::get_if<EncodableMap>(call.arguments())) {
            auto it = a->find(EncodableValue(std::string("label")));
            if (it != a->end()) {
              if (const auto* s = std::get_if<std::string>(&it->second)) {
                perf::Mark(*s);
              }
            }
          }
          result->Success();
        } else if (m == "shareSheet") {
          result->Success();  // Windows v1: no system share surface
        } else if (m == "openSettings") {
          // Hand our foreground right to the main process so the Settings
          // window can take focus.
          AllowSetForegroundWindow(link_->main_pid());
          link_->Call("openSettings", EncodableValue());
          result->Success();
        } else if (m == "setWindowTitle") {
          // The editor Dart pushes its localized title (app_language) so the OS
          // caption follows the language setting; native owns no l10n strings.
          if (const auto* s = std::get_if<std::string>(call.arguments())) {
            if (GetHandle() && !s->empty()) {
              SetWindowTextW(GetHandle(), Utf16FromUtf8(*s).c_str());
            }
          }
          result->Success();
        } else if (m == "titleBarDoubleClick") {
          result->Success();  // the standard caption bar handles maximize itself
        } else {
          result->NotImplemented();
        }
      });

  // The editor uses the clipboard (paste / copy) and native encode (export), so
  // register those seams on this engine too (Dart degrades if absent, but native
  // is faster + enables clipboard paste).
  clipboard_channel_ = std::make_unique<ClipboardChannel>(messenger);
  encode_channel_ = std::make_unique<EncodeChannel>(messenger);
  sound_channel_ = std::make_unique<SoundChannel>(messenger);
  // The text tool's font popover (the same enumerator the overlay uses).
  fonts_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "glimpr/fonts", &flutter::StandardMethodCodec::GetInstance());
  fonts_channel_->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "availableFamilies") {
      result->Success(EnumerateFontFamilies());
    } else {
      result->NotImplemented();
    }
  });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  // Accept Explorer image drags anywhere on the window (parity with macOS
  // registerForDraggedTypes, including the hover-time veto). The Flutter child
  // view registers no target, so OLE resolves up the ancestor chain to here.
  drop_target_ = new EditorDropTarget(this);
  RegisterDragDrop(GetHandle(), drop_target_);
  return true;
}

void EditorWindow::OnDestroy() {
  if (drop_target_) {
    if (GetHandle()) RevokeDragDrop(GetHandle());
    static_cast<EditorDropTarget*>(drop_target_)->Detach();
    drop_target_->Release();
    drop_target_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  Win32Window::OnDestroy();
}

LRESULT EditorWindow::MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam) noexcept {
  switch (message) {
    case WM_CLOSE:
      // Mirror macOS: ask Dart to run its unsaved-changes check; Dart calls
      // hideEditor to hide, which arms the host's exit gate. Never fall
      // through to the default destroy (the engine must not be torn down
      // in-process; the process exit reclaims it).
      if (editor_channel_) {
        editor_channel_->InvokeMethod("requestClose", nullptr);
      } else {
        CapturePlacement();
        ShowWindow(hwnd, SW_HIDE);
        link_->Hidden();
      }
      return 0;
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      UINT dpi = FlutterDesktopGetDpiForMonitor(
          MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST));
      double scale = dpi / 96.0;
      RECT min_client = {0, 0, static_cast<LONG>(kMinW * scale),
                         static_cast<LONG>(kMinH * scale)};
      AdjustWindowRectExForDpi(&min_client, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi);
      info->ptMinTrackSize.x = min_client.right - min_client.left;
      info->ptMinTrackSize.y = min_client.bottom - min_client.top;
      return 0;
    }
    case WM_ACTIVATE:
      // Tell Dart so it reloads settings + reclaims canvas focus on refocus
      // (e.g. returning from the Settings window). Fall through to Flutter/base
      // so focus + input still work.
      if (editor_channel_) {
        editor_channel_->InvokeMethod(
            LOWORD(wparam) == WA_INACTIVE ? "windowResignedKey"
                                          : "windowBecameKey",
            nullptr);
      }
      break;
    case WM_SETTINGCHANGE:
      // System light/dark toggle: re-theme the title bar BEFORE the engine
      // sees the message (belt and braces with the Win32Window base handler,
      // in case the engine consumes WM_SETTINGCHANGE).
      if (lparam &&
          lstrcmpiW(reinterpret_cast<const wchar_t*>(lparam),
                    L"ImmersiveColorSet") == 0) {
        UpdateTheme(hwnd);
      }
      break;
    default:
      break;
  }

  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) return *result;
  }
  if (message == WM_FONTCHANGE && flutter_controller_) {
    flutter_controller_->engine()->ReloadSystemFonts();
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
