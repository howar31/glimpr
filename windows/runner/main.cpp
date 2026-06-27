#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Single instance: a resident tray app must not run twice (a second tray icon
  // + a RegisterHotKey collision). If one is already running, ask it to reveal
  // its Settings window, then exit.
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, TRUE, L"Glimpr_SingleInstance_8F3A");
  if (instance_mutex && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    UINT reveal = ::RegisterWindowMessageW(L"GlimprRevealSettings");
    ::PostMessage(HWND_BROADCAST, reveal, 0, 0);
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // Initial CONTENT size, matching the macOS Settings window (820x700 pts).
  // Win32Window::Create treats this as the client area and adds the DPI frame.
  Win32Window::Size size(820, 700);
  if (!window.Create(L"Glimpr", origin, size)) {
    return EXIT_FAILURE;
  }
  // Resident shell: closing the Settings window hides it to the tray; only the
  // tray "Quit" (FlutterWindow::Quit -> PostQuitMessage) ends the app.
  window.SetQuitOnClose(false);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
