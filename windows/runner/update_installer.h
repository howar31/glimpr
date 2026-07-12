#ifndef RUNNER_UPDATE_INSTALLER_H_
#define RUNNER_UPDATE_INSTALLER_H_

#include <string>

// Installed-build self-update (the glimpr/update channel's native half).
// Portable builds are unsupported by design: the Dart side falls back to
// opening the release page whenever UpdateSupported() is false.
namespace update_installer {

// True when this process runs from the Inno-installed location: the exe's
// directory matches the uninstall registry's InstallLocation (HKLM or HKCU,
// case-insensitive, trailing-separator-agnostic).
bool UpdateSupported();

// Verify the staged installer's detached Ed25519 signature against the
// embedded release public key; on success strip the Mark-of-the-Web and
// spawn a detached watcher that waits for this process to exit, runs the
// installer silently, then relaunches the app. Returns true when the watcher
// was spawned (the caller must then exit); false = nothing was changed.
bool ApplyStaged(const std::wstring& exe_path, const std::wstring& sig_path);

}  // namespace update_installer

#endif  // RUNNER_UPDATE_INSTALLER_H_
