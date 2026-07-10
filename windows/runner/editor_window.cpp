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
#include "perf_log.h"
#include "pin_window.h"
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

EditorWindow::EditorWindow(const flutter::DartProject& project, HWND control_hwnd)
    : project_(project), control_hwnd_(control_hwnd) {}

EditorWindow::~EditorWindow() {}

void EditorWindow::WarmUp() { EnsureCreated(); }

void EditorWindow::EnsureCreated() {
  if (GetHandle()) return;  // already built (warm or lazy)
  // A sensible default position near the top-left; the window is movable.
  Win32Window::Point origin(80, 60);
  Win32Window::Size size(kDefaultW, kDefaultH);
  Create(L"Image Editor", origin, size);  // -> OnCreate builds the engine
  SetQuitOnClose(false);  // close hides to the engine-warm state, never quits
}

void EditorWindow::RevealEditor() {
  EnsureCreated();
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  ShowWindow(hwnd, SW_SHOW);
  if (flutter_controller_) flutter_controller_->ForceRedraw();
  SetForegroundWindow(hwnd);
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

void EditorWindow::SetRecentImagesCallback(
    std::function<void(std::vector<std::string>)> cb) {
  recent_cb_ = std::move(cb);
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
          result->Success();
        } else if (m == "hideEditor") {
          if (GetHandle()) ShowWindow(GetHandle(), SW_HIDE);
          result->Success();
        } else if (m == "setRecentImages") {
          std::vector<std::string> list;
          if (const auto* l = std::get_if<EncodableList>(call.arguments())) {
            for (const auto& v : *l) {
              if (const auto* s = std::get_if<std::string>(&v)) {
                list.push_back(*s);
              }
            }
          }
          if (recent_cb_) recent_cb_(list);
          result->Success();
        } else if (m == "pinImage") {
          // The editor's pin flow leg: float the image centered (no rect).
          if (pin_manager_) {
            if (const auto* a = std::get_if<EncodableMap>(call.arguments())) {
              auto it = a->find(EncodableValue(std::string("path")));
              if (it != a->end()) {
                if (const auto* p = std::get_if<std::string>(&it->second)) {
                  pin_manager_->Pin(*p, std::nullopt);
                }
              }
            }
          }
          result->Success();
        } else if (m == "setProcessing") {
          // Editor Done/export commit (true) / delivered (false): relay to the
          // control engine's tray to drive the logo-gradient processing pulse.
          // The optional label becomes the tray's hover tooltip while pulsing.
          bool active = false;
          std::string label;
          if (const auto* a = std::get_if<EncodableMap>(call.arguments())) {
            auto it = a->find(EncodableValue(std::string("active")));
            if (it != a->end()) {
              if (const auto* b = std::get_if<bool>(&it->second)) active = *b;
            }
            auto lt = a->find(EncodableValue(std::string("label")));
            if (lt != a->end()) {
              if (const auto* s = std::get_if<std::string>(&lt->second)) {
                label = *s;
              }
            }
          }
          if (proc_cb_) proc_cb_(active, label);
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
          if (control_hwnd_) {
            static UINT reveal = RegisterWindowMessageW(L"GlimprRevealSettings");
            PostMessage(control_hwnd_, reveal, 0, 0);
          }
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
      // hideEditor to hide. The window is never destroyed (the engine stays
      // warm), so do NOT fall through to the default destroy.
      if (editor_channel_) {
        editor_channel_->InvokeMethod("requestClose", nullptr);
      } else {
        ShowWindow(hwnd, SW_HIDE);
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
      // in case the engine consumes WM_SETTINGCHANGE). The warm editor window
      // exists from boot, so its title bar must follow the live toggle.
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
