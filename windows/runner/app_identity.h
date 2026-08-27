#ifndef RUNNER_APP_IDENTITY_H_
#define RUNNER_APP_IDENTITY_H_

// Build identity. Official builds are "Glimpr"; a dev build (configured with
// GLIMPR_DEV=1 in the environment, see runner/CMakeLists.txt) is "GlimprDev"
// with its own exe name, VERSIONINFO ProductName (which also moves the
// settings dir to %APPDATA%\Howar31\GlimprDev), single-instance mutex, and
// reveal broadcast -- so a dev build and the installed copy never collide and
// are distinguishable in the tray, Task Manager, and on disk. Mirrors the
// macOS Debug-config GlimprDev identity (AppInfo.xcconfig).
#ifdef GLIMPR_DEV_IDENTITY
#define GLIMPR_APP_NAME "GlimprDev"
#define GLIMPR_APP_NAME_W L"GlimprDev"
#define GLIMPR_MUTEX_NAME_W L"GlimprDev_SingleInstance_8F3A"
#define GLIMPR_REVEAL_MESSAGE_W L"GlimprDevRevealSettings"
#else
#define GLIMPR_APP_NAME "Glimpr"
#define GLIMPR_APP_NAME_W L"Glimpr"
#define GLIMPR_MUTEX_NAME_W L"Glimpr_SingleInstance_8F3A"
#define GLIMPR_REVEAL_MESSAGE_W L"GlimprRevealSettings"
#endif

#endif  // RUNNER_APP_IDENTITY_H_
