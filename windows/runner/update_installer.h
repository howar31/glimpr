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

enum class ApplyResult {
  kLaunched,   // installer running elevated; the caller must exit now
  kCancelled,  // the user declined the elevation prompt; nothing changed
  kRejected,   // signature / launch failure; nothing changed
};

// Verify the staged installer's detached Ed25519 signature against the
// embedded release public key; on success strip the Mark-of-the-Web and
// launch the installer silently WHILE THIS PROCESS STILL RUNS, so the
// elevation prompt appears first: declining it leaves the app running
// (kCancelled). On consent the installer waits for this process id to exit
// (its /PID parameter, see windows/installer/glimpr.iss) before replacing
// files, then relaunches the app un-elevated.
ApplyResult ApplyStaged(const std::wstring& exe_path,
                        const std::wstring& sig_path);

}  // namespace update_installer

#endif  // RUNNER_UPDATE_INSTALLER_H_
