#include "flutter_window.h"

#include <commctrl.h>
#include <shellapi.h>
#include <wincred.h>

#include <cmath>
#include <cstdio>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "app_identity.h"
#include "diagnostics.h"
#include "flutter/generated_plugin_registrant.h"
#include "install_scope.h"
#include "perf_log.h"
#include "update_installer.h"
#include "utils.h"
#include "win_reveal.h"

using flutter::EncodableMap;
using flutter::EncodableList;
using flutter::EncodableValue;

namespace {
// Deferred overlay warm-up: pre-create the per-display overlay engines this long
// after launch (off the launch critical path) so the first capture is instant.
// A capture during the delay just lazy-creates them itself (no regression).
constexpr UINT_PTR kWarmupTimerId = 0xB001;
constexpr UINT kWarmupDelayMs = 2000;

// The running executable's full path.
std::wstring ExePath() {
  wchar_t buf[MAX_PATH];
  GetModuleFileNameW(nullptr, buf, MAX_PATH);
  return std::wstring(buf);
}

// Spawn a detached watcher that, after a short delay (long enough for this
// force-exited process to die + release the single-instance mutex), starts a
// fresh instance. cmd.exe resolves from System32 (powershell.exe lives in a
// System32 SUBDIR that CreateProcessW does not search, so it may fail to spawn);
// `ping` is a console-less delay; `start` launches the exe. NO goto/labels --
// they do not work in a `cmd /c` one-liner, so the previous loop never fired.
void RelaunchApp() {
  std::wstring exe = ExePath();
  wchar_t cmd[1024];
  swprintf_s(cmd,
    L"cmd.exe /c \"ping -n 3 127.0.0.1 >nul & start \"\" \"%ls\"\"",
    exe.c_str());
  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi = {};
  if (CreateProcessW(nullptr, cmd, nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
                     nullptr, nullptr, &si, &pi)) {
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  }
}

// Launch-at-login: a per-user HKCU Run value pointing at the exe.
constexpr wchar_t kRunKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"Glimpr";

bool IsLaunchAtLogin() {
  HKEY key;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_READ, &key) !=
      ERROR_SUCCESS) {
    return false;
  }
  LONG r = RegQueryValueExW(key, kRunValue, nullptr, nullptr, nullptr, nullptr);
  RegCloseKey(key);
  return r == ERROR_SUCCESS;
}

void SetLaunchAtLogin(bool enable) {
  HKEY key;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_SET_VALUE, &key) !=
      ERROR_SUCCESS) {
    return;
  }
  if (enable) {
    std::wstring quoted = L"\"" + ExePath() + L"\"";
    RegSetValueExW(
        key, kRunValue, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(quoted.c_str()),
        static_cast<DWORD>((quoted.size() + 1) * sizeof(wchar_t)));
  } else {
    RegDeleteValueW(key, kRunValue);
  }
  RegCloseKey(key);
}

// Pro license blob storage -- the Windows Credential Manager (the "Credential
// Locker"), the analogue of the macOS Keychain generic-password item. Dumb
// storage only: all verification is Dart-side against the embedded public key,
// and the OSS/stub build never invokes the channel (the gate ships dormant).
// Stored as a per-user generic credential keyed by a fixed target name; the
// blob is the UTF-8 license string (a signed entitlement, a few hundred bytes,
// well under CRED_MAX_CREDENTIAL_BLOB_SIZE). Persisted LOCAL_MACHINE so it
// survives logoff/reboot for this user without roaming.
constexpr wchar_t kLicenseTarget[] = L"com.howar31.glimpr.license";
constexpr wchar_t kLicenseUser[] = L"license";

std::optional<std::string> LicenseRead() {
  PCREDENTIALW cred = nullptr;
  if (!CredReadW(kLicenseTarget, CRED_TYPE_GENERIC, 0, &cred) || !cred) {
    return std::nullopt;
  }
  std::string value(reinterpret_cast<const char*>(cred->CredentialBlob),
                    cred->CredentialBlobSize);
  CredFree(cred);
  return value;
}

void LicenseWrite(const std::string& value) {
  CREDENTIALW cred = {};
  cred.Type = CRED_TYPE_GENERIC;
  cred.TargetName = const_cast<wchar_t*>(kLicenseTarget);
  cred.UserName = const_cast<wchar_t*>(kLicenseUser);
  cred.CredentialBlob =
      reinterpret_cast<LPBYTE>(const_cast<char*>(value.data()));
  cred.CredentialBlobSize = static_cast<DWORD>(value.size());
  cred.Persist = CRED_PERSIST_LOCAL_MACHINE;
  CredWriteW(&cred, 0);
}

void LicenseClear() {
  CredDeleteW(kLicenseTarget, CRED_TYPE_GENERIC, 0);  // ERROR_NOT_FOUND is fine
}
}  // namespace

UINT FlutterWindow::reveal_message_ = 0;

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  auto* messenger = flutter_controller_->engine()->messenger();

  // Native capture/clipboard channels (in-runner, mirroring macOS).
  capture_channel_ = std::make_unique<CaptureChannel>(messenger);
  clipboard_channel_ = std::make_unique<ClipboardChannel>(messenger);
  sound_channel_ = std::make_unique<SoundChannel>(messenger);

  // This is the CONTROL engine: answer glimpr/role (so main.dart mounts the
  // Settings app without the retry) plus the Settings surface the shared
  // settings UI invokes (close / about / version / external links / relaunch).
  role_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "glimpr/role",
      &flutter::StandardMethodCodec::GetInstance());
  role_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const auto& m = call.method_name();
        if (m == "getRole") {
          result->Success(EncodableValue("control"));
        } else if (m == "closeSettings") {
          ShowWindow(GetHandle(), SW_HIDE);  // close = hide to tray
          result->Success();
        } else if (m == "setShortcutRecording") {
          result->Success();  // no native key interceptor on Windows -> no-op
        } else if (m == "appVersion") {
          result->Success(EncodableValue(AppVersionString()));
        } else if (m == "diagnostics") {
          // Report-an-issue page: environment snapshot, on demand only.
          result->Success(diag::Collect());
        } else if (m == "appIsDev") {
          // Display-only dev-identity flag (app_identity.h). appVersion stays
          // pure -- the update compare parses it.
#ifdef GLIMPR_DEV_IDENTITY
          result->Success(EncodableValue(true));
#else
          result->Success(EncodableValue(false));
#endif
        } else if (m == "openExternalUrl") {
          if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
            auto it = args->find(EncodableValue(std::string("url")));
            if (it != args->end()) {
              if (const auto* url = std::get_if<std::string>(&it->second)) {
                std::wstring wurl(url->begin(), url->end());
                ShellExecuteW(nullptr, L"open", wurl.c_str(), nullptr, nullptr,
                              SW_SHOWNORMAL);
              }
            }
          }
          result->Success();
        } else if (m == "relaunch") {
          RelaunchApp();
          if (tray_icon_) tray_icon_->Remove();
          if (overlay_host_) overlay_host_->Shutdown();
          if (editor_host_) editor_host_->Shutdown();
          result->Success();
          // Force-exit: PostQuitMessage relies on a clean message-loop teardown,
          // but tearing down the overlay + editor Flutter engines on the way out
          // can hang, leaving the relaunch watcher waiting forever. ExitProcess
          // guarantees the old process dies so the watcher restarts us.
          ExitProcess(0);
        } else if (m == "openImageEditor") {
          if (editor_host_) editor_host_->Reveal();
          result->Success();
        } else if (m == "openImageEditorClipboard") {
          if (editor_host_) editor_host_->LoadClipboard();
          result->Success();
        } else if (m == "openImageEditorPath") {
          // After-recording flow: reveal the editor and load a path (a .gif
          // mounts the GIF surface inside the Image Editor).
          std::string path;
          if (const auto* a = std::get_if<EncodableMap>(call.arguments())) {
            auto it = a->find(EncodableValue(std::string("path")));
            if (it != a->end()) {
              if (const auto* s = std::get_if<std::string>(&it->second)) {
                path = *s;
              }
            }
          }
          if (editor_host_ && !path.empty()) {
            editor_host_->OpenWithPath(path);  // reveals itself
          }
          result->Success();
        } else if (m == "setRecentImages") {
          // The control engine's Dart owns the tray "Open Recent" list on
          // Windows (the editor engine only exists while the editor is open).
          std::vector<std::string> list;
          if (const auto* l = std::get_if<EncodableList>(call.arguments())) {
            for (const auto& v : *l) {
              if (const auto* s = std::get_if<std::string>(&v)) {
                list.push_back(*s);
              }
            }
          }
          if (tray_icon_) tray_icon_->SetRecentImages(std::move(list));
          result->Success();
        } else if (m == "setTrayLabels") {
          // The control engine's Dart pushes the localized tray-menu labels
          // (the runner C++ is ASCII-only, so it cannot hold the zh strings).
          std::map<std::string, std::string> labels;
          if (const auto* map = std::get_if<EncodableMap>(call.arguments())) {
            for (const auto& kv : *map) {
              const auto* k = std::get_if<std::string>(&kv.first);
              const auto* v = std::get_if<std::string>(&kv.second);
              if (k && v) labels[*k] = *v;
            }
          }
          if (tray_icon_) tray_icon_->SetLabels(std::move(labels));
          result->Success();
        } else if (m == "setUpdateStatus") {
          // Update-check state for the tray item (label + availability);
          // pushed by Dart whenever the About row's state changes.
          if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
            const auto label_it = args->find(EncodableValue(std::string("label")));
            const auto avail_it =
                args->find(EncodableValue(std::string("available")));
            const auto* label = label_it != args->end()
                                    ? std::get_if<std::string>(&label_it->second)
                                    : nullptr;
            const auto* avail = avail_it != args->end()
                                    ? std::get_if<bool>(&avail_it->second)
                                    : nullptr;
            if (tray_icon_ && label && avail) {
              tray_icon_->SetUpdateStatus(*label, *avail);
            }
          }
          result->Success();
        } else if (m == "revealInExplorer") {
          if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
            auto it = args->find(EncodableValue(std::string("path")));
            if (it != args->end()) {
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

  // Launch-at-login (HKCU Run key).
  login_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "glimpr/login",
      &flutter::StandardMethodCodec::GetInstance());
  login_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const auto& m = call.method_name();
        if (m == "isEnabled") {
          result->Success(EncodableValue(IsLaunchAtLogin()));
        } else if (m == "setEnabled") {
          bool enable = false;
          if (const auto* b = std::get_if<bool>(call.arguments())) enable = *b;
          SetLaunchAtLogin(enable);
          result->Success(EncodableValue(IsLaunchAtLogin()));
        } else {
          result->NotImplemented();
        }
      });

  // Pro license blob storage -- Credential Manager read/write/clear (the macOS
  // Keychain analogue). Dumb storage only; all verification is Dart-side against
  // the embedded public key, and the OSS/stub build never invokes this channel.
  // Control engine only (Settings owns license activation); the overlay/editor
  // engines fall through to "no license" until a Pro feature lives there.
  license_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "glimpr/license",
      &flutter::StandardMethodCodec::GetInstance());
  license_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const auto& m = call.method_name();
        if (m == "read") {
          if (auto v = LicenseRead()) {
            result->Success(EncodableValue(*v));
          } else {
            result->Success();  // no license stored -> Dart null
          }
        } else if (m == "write") {
          if (const auto* v = std::get_if<std::string>(call.arguments())) {
            LicenseWrite(*v);
          }
          result->Success();
        } else if (m == "clear") {
          LicenseClear();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  // Installed-build self-update (glimpr/update): the Dart updater stages a
  // verified download and this applies it (Ed25519 check + silent installer +
  // relaunch watcher). Control engine only. Success(true) means the watcher
  // is live and THIS process force-exits (mirrors the relaunch handler).
  update_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "glimpr/update",
      &flutter::StandardMethodCodec::GetInstance());
  update_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const auto& m = call.method_name();
        if (m == "updateSupported") {
          result->Success(EncodableValue(update_installer::UpdateSupported()));
        } else if (m == "installScope") {
          // Settings > Advanced install-scope row: which scope this copy
          // runs from (null = portable / dev tree, row hidden) and whether
          // the account may switch it.
          const auto scope = update_installer::CurrentScope();
          EncodableMap out;
          if (scope == install_scope::Scope::kNone) {
            out[EncodableValue("scope")] = EncodableValue();
          } else {
            out[EncodableValue("scope")] =
                EncodableValue(install_scope::ScopeName(scope));
          }
          out[EncodableValue("admin")] =
              EncodableValue(update_installer::IsAdminAccount());
          result->Success(EncodableValue(out));
        } else if (m == "applyStaged") {
          std::wstring exe_path;
          std::wstring sig_path;
          std::string scope;
          if (const auto* args =
                  std::get_if<EncodableMap>(call.arguments())) {
            for (const auto& kv : *args) {
              const auto* k = std::get_if<std::string>(&kv.first);
              const auto* v = std::get_if<std::string>(&kv.second);
              if (!k || !v) continue;
              std::wstring wide = Utf16FromUtf8(*v);
              if (*k == "path") exe_path = wide;
              if (*k == "sigPath") sig_path = wide;
              if (*k == "scope") scope = *v;
            }
          }
          const auto applied =
              exe_path.empty() || sig_path.empty()
                  ? update_installer::ApplyResult::kRejected
                  : update_installer::ApplyStaged(
                        exe_path, sig_path,
                        install_scope::TargetFromString(scope));
          if (applied == update_installer::ApplyResult::kCancelled) {
            // Declined elevation: the app keeps running, the staged file
            // stays for the next tap (no error, per the UAC guidelines).
            result->Success(EncodableValue("cancelled"));
          } else if (applied == update_installer::ApplyResult::kLaunched) {
            if (tray_icon_) tray_icon_->Remove();
            result->Success(EncodableValue(true));
            // Exit AFTER a short beat so the Settings UI can paint its
            // "installing, restarting" state. The elevated installer waits
            // on this process id before replacing files, and force-exit is
            // still required: a clean engine teardown can hang (same
            // rationale as the relaunch handler).
            // The installer replaces the exe the overlay host also maps: end
            // the host now, on this thread, not from the exit thread below.
            if (overlay_host_) overlay_host_->Shutdown();
            if (editor_host_) editor_host_->Shutdown();
            CreateThread(
                nullptr, 0,
                [](LPVOID) -> DWORD {
                  Sleep(1200);
                  ExitProcess(0);
                },
                nullptr, 0, nullptr);
            return;
          }
          result->Success(EncodableValue(false));
        } else {
          result->NotImplemented();
        }
      });

  // Screen recording (glimpr/record): WGC continuous capture -> Media Foundation
  // sink writer. Control engine only, like the macOS RecordingChannel. The HWND
  // is the async-event target (a background encoder failure posts WM_GLIMPR_RECORD
  // back here so the Dart event is emitted on the platform thread).
  record_channel_ = std::make_unique<RecordChannel>(messenger, GetHandle());

  // Global hotkeys (Win32 RegisterHotKey, fired via WM_HOTKEY to this window).
  hotkey_host_ = std::make_unique<HotkeyHost>(messenger, GetHandle());

  // The freeze overlay runs in a child process (overlay_host.h). Everything it
  // needs from this resident side arrives as a one-way call; the targets are
  // created below and looked up when a call lands.
  OverlayHostClient::Callbacks overlay_calls;
  overlay_calls.open_in_editor = [this](const std::string& path) {
    if (editor_host_) editor_host_->OpenWithPath(path);
  };
  overlay_calls.recent_changed = [this]() { RecentChanged(); };
  overlay_calls.pin_image = [this](const flutter::EncodableMap& args) {
    PinFromOverlay(args);
  };
  overlay_calls.open_settings = [this]() { RevealControlWindow(); };
  // The record-select picker lives on an overlay engine; its confirm/cancel
  // relays to the control engine's record channel (-> Dart RecordController).
  overlay_calls.record_selection = [this](flutter::EncodableValue args) {
    if (record_channel_) record_channel_->RelaySelection(std::move(args));
  };
  overlay_calls.set_processing = [this](bool active, const std::string& label) {
    if (tray_icon_) tray_icon_->SetProcessing(active, label);  // overlay
  };
  overlay_host_ = std::make_unique<OverlayHostClient>(GetHandle(),
                                                      std::move(overlay_calls));
  capture_channel_->SetOverlayHost(overlay_host_.get());
  // Async direct-capture completions marshal back through this window
  // (WM_GLIMPR_CAPTURE in MessageHandler).
  capture_channel_->SetControlHwnd(GetHandle());

  // The standalone Image Editor lives in a child process spawned on the first
  // open (editor_host.h). Its one-way calls land on the resident objects
  // created below; the callbacks look them up when a call arrives.
  EditorHostClient::Callbacks editor_calls;
  editor_calls.set_recent_images = [this](std::vector<std::string> paths) {
    if (tray_icon_) tray_icon_->SetRecentImages(std::move(paths));
  };
  editor_calls.pin_image = [this](const std::string& path) {
    // The editor's pin flow leg: float the image centered (no rect).
    if (pin_manager_) pin_manager_->Pin(path, std::nullopt);
  };
  editor_calls.set_processing = [this](bool active, const std::string& label) {
    if (tray_icon_) tray_icon_->SetProcessing(active, label);  // editor
  };
  editor_calls.open_settings = [this]() { RevealControlWindow(); };
  editor_host_ = std::make_unique<EditorHostClient>(GetHandle(),
                                                    std::move(editor_calls));
  // The capture flow's open-in-editor leg + recents relay reach the editor from
  // both the direct-capture (control) and overlay engines.
  capture_channel_->SetEditorHost(editor_host_.get());
  capture_channel_->SetRecentChangedCallback([this]() { RecentChanged(); });

  // The shared pin manager: the pin flow leg reaches it from the control, overlay
  // and editor engines.
  pin_manager_ = std::make_unique<PinManager>();
  capture_channel_->SetPinManager(pin_manager_.get());

  // System tray (the menu-bar analogue). Live items fire through the same Dart
  // dispatcher as the hotkeys; Settings / About / Quit are native callbacks.
  tray_icon_ = std::make_unique<TrayIcon>(
      GetHandle(), GetModuleHandle(nullptr), hotkey_host_.get(),
      TrayIcon::Callbacks{
          [this]() { RevealControlWindow(); },
          [this]() {
            RevealControlWindow();
            role_channel_->InvokeMethod("showAbout", nullptr);
          },
          [this]() { Quit(); },
          [this](const std::string& path) {
            if (editor_host_) editor_host_->OpenWithPath(path);
          },
          [this]() {
            // The control engine's Dart owns the list; a live editor reloads
            // its gallery from the cleared store.
            if (role_channel_) role_channel_->InvokeMethod("clearRecent", nullptr);
            if (editor_host_) editor_host_->ClearRecent();
          },
          [this]() {
            // Always reveal Settings first. Dart then lands on About and
            // either runs the check there (the row is the feedback) or, with
            // a known update, opens the What's-new page so the user reads
            // what is coming before installing from the About row.
            RevealControlWindow();
            role_channel_->InvokeMethod("trayCheckUpdates", nullptr);
          },
      });
  // The tray mark reflects the recording state (red breathing while recording).
  record_channel_->SetRecordingStateCallback([this](bool active, bool graceful) {
    if (tray_icon_) tray_icon_->SetRecordingState(active, graceful);
  });
  // The tray mark pulses the logo gradient (cyan->blue->violet) while a capture
  // export / recording finalize / editor export is in flight -- mirrors macOS
  // setProcessing. All three sources route to the single control-engine tray.
  // Each source also carries a localized tooltip label (what is processing);
  // the recording one is native-initiated, so its label comes from the pushed
  // tray-label map instead of a channel argument.
  record_channel_->SetProcessingCallback([this](bool active) {
    if (tray_icon_) {
      tray_icon_->SetProcessing(
          active,
          tray_icon_->Label("processingRecording", "Processing recording..."),
          /*unbounded=*/true);
    }
  });
  capture_channel_->SetProcessingCallback(
      [this](bool active, const std::string& label) {
        if (tray_icon_) tray_icon_->SetProcessing(active, label);  // direct
      });

  // A second instance posts this to reveal the running one's Settings.
  reveal_message_ = RegisterWindowMessageW(GLIMPR_REVEAL_MESSAGE_W);

  // Deferred background warm-up: a short while after launch, pre-build the
  // overlay engines (instant first capture), off the launch critical path.
  SetTimer(GetHandle(), kWarmupTimerId, kWarmupDelayMs, nullptr);

  HWND view_hwnd = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(view_hwnd);
  // Subclass the view so the Settings recorder can capture keys Flutter drops
  // (PrintScreen, the Win key). Active only while HotkeyHost::Capturing().
  SetWindowSubclass(view_hwnd, &FlutterWindow::KeyCaptureSubclassProc, 1,
                    reinterpret_cast<DWORD_PTR>(this));

  // Resident shell: start HIDDEN in the tray (no window at launch, mirroring the
  // macOS at-rest accessory). main.dart still runs (registers hotkeys + builds
  // the tray) without frames; the first frame is produced on the first
  // RevealControlWindow (tray double-click / "Settings" / overlay openSettings).

  perf::Mark("trayReady");
  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::RevealControlWindow() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  ShowWindow(hwnd, SW_SHOW);
  if (flutter_controller_) flutter_controller_->ForceRedraw();
  SetForegroundWindow(hwnd);
}

void FlutterWindow::RecentChanged() {
  if (role_channel_) role_channel_->InvokeMethod("refreshRecent", nullptr);
  if (editor_host_) editor_host_->RefreshRecent();
}

void FlutterWindow::PinFromOverlay(const flutter::EncodableMap& args) {
  // The overlay flow's pin leg: float the image at [path] in place over the
  // captured region (x/y/w/h global logical) when present, else centered.
  auto number = [&args](const char* key, double* out) {
    auto it = args.find(flutter::EncodableValue(std::string(key)));
    if (it == args.end()) return false;
    if (const auto* d = std::get_if<double>(&it->second)) {
      *out = *d;
      return true;
    }
    if (const auto* i = std::get_if<int32_t>(&it->second)) {
      *out = *i;
      return true;
    }
    if (const auto* l = std::get_if<int64_t>(&it->second)) {
      *out = static_cast<double>(*l);
      return true;
    }
    return false;
  };
  auto path_it = args.find(flutter::EncodableValue(std::string("path")));
  if (path_it == args.end() || !pin_manager_) return;
  const auto* path = std::get_if<std::string>(&path_it->second);
  if (!path || path->empty()) return;
  std::optional<RECT> place;
  double x = 0, y = 0, w = 0, h = 0;
  if (number("w", &w) && number("h", &h)) {
    number("x", &x);
    number("y", &y);
    place = RECT{static_cast<LONG>(std::lround(x)),
                 static_cast<LONG>(std::lround(y)),
                 static_cast<LONG>(std::lround(x + w)),
                 static_cast<LONG>(std::lround(y + h))};
  }
  pin_manager_->Pin(*path, place);
}

void FlutterWindow::Quit() {
  if (tray_icon_) tray_icon_->Remove();
  // The overlay host's windows are not ours: end it before we go.
  if (overlay_host_) overlay_host_->Shutdown();
  if (editor_host_) editor_host_->Shutdown();
  // Force-exit instead of PostQuitMessage: the clean message-loop teardown
  // destroys the editor + per-display overlay Flutter engines before the main
  // HWND, so the still-visible windows linger for seconds after the tray icon
  // is gone (and the teardown can hang outright -- same reason the relaunch
  // path force-exits). Process death destroys every window at once and closes
  // the record worker's stdin, which makes an in-flight worker abort itself.
  ExitProcess(0);
}

LRESULT CALLBACK FlutterWindow::KeyCaptureSubclassProc(HWND hwnd, UINT message,
                                                       WPARAM wparam,
                                                       LPARAM lparam,
                                                       UINT_PTR /*id*/,
                                                       DWORD_PTR ref) {
  auto* self = reinterpret_cast<FlutterWindow*>(ref);
  if (self && self->hotkey_host_ && self->hotkey_host_->Capturing() &&
      (message == WM_KEYDOWN || message == WM_KEYUP ||
       message == WM_SYSKEYDOWN || message == WM_SYSKEYUP)) {
    if (self->hotkey_host_->HandleCaptureMessage(message, wparam, lparam)) {
      return 0;  // consumed: Flutter never sees the key while recording
    }
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Resident-shell messages, handled before Flutter / the base window proc.
  if (message == WM_HOTKEY && hotkey_host_) {
    hotkey_host_->Fire(static_cast<int>(wparam));
    return 0;
  }
  if (message == WM_GLIMPR_TRAY && tray_icon_) {
    tray_icon_->OnTrayMessage(wparam, lparam);
    return 0;
  }
  if (message == WM_GLIMPR_RECORD && record_channel_) {
    // A background recorder thread marshalled an async event (e.g. an encode
    // failure) back to the platform thread so the Dart event is safe to emit.
    record_channel_->OnNativeEvent(static_cast<uint32_t>(wparam));
    return 0;
  }
  if (message == WM_GLIMPR_CAPTURE && capture_channel_) {
    // A direct-capture worker finished: complete its method result on the
    // platform thread (Flutter method results are not thread-safe).
    capture_channel_->OnAsyncDone();
    return 0;
  }
  if (message == WM_GLIMPR_OVERLAY_HOST && overlay_host_) {
    // The overlay host's reader thread queued a line (or its exit).
    overlay_host_->OnHostMessage();
    return 0;
  }
  if (message == WM_GLIMPR_EDITOR_HOST && editor_host_) {
    editor_host_->OnHostMessage();
    return 0;
  }
  if (message == WM_TIMER && wparam == kWarmupTimerId) {
    KillTimer(GetHandle(), kWarmupTimerId);  // one-shot
    perf::Mark("warmupBegin");
    if (overlay_host_) overlay_host_->WarmUp();
    perf::Mark("warmupEnd");
    return 0;
  }
  if (message == WM_CLOSE) {
    ShowWindow(GetHandle(), SW_HIDE);  // close = hide to tray; do not destroy
    return 0;
  }
  if (reveal_message_ != 0 && message == reveal_message_) {
    RevealControlWindow();  // a second instance asked us to show Settings
    return 0;
  }
  // Taskbar light/dark flip -> re-tint the tray mark AND re-theme this
  // window's title bar (the hidden-at-boot Settings window otherwise keeps its
  // creation-time title-bar mode forever). Non-consuming: Flutter still
  // receives WM_SETTINGCHANGE to update its own theme; the title-bar update
  // runs here, before the engine, in case the engine consumes the message.
  if (message == WM_SETTINGCHANGE && lparam &&
      lstrcmpiW(reinterpret_cast<const wchar_t*>(lparam),
                L"ImmersiveColorSet") == 0) {
    if (tray_icon_) tray_icon_->OnThemeChanged();
    UpdateTheme(hwnd);
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
