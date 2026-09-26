#ifndef RUNNER_UPDATE_INSTALLER_H_
#define RUNNER_UPDATE_INSTALLER_H_

#include <string>

#include "install_scope.h"

// Installed-build self-update (the glimpr/update channel's native half).
// Portable builds are unsupported by design: the Dart side falls back to
// opening the release page whenever UpdateSupported() is false.
namespace update_installer {

// The scope this process runs from: the exe's directory matches the
// uninstall registry's InstallLocation under HKLM (machine) or HKCU (user),
// case-insensitive, trailing-separator-agnostic. kNone otherwise.
install_scope::Scope CurrentScope();

// True when this process runs from an Inno-installed location.
bool UpdateSupported();

// Whether the account is a member of BUILTIN\Administrators, judged on the
// full (linked) token when UAC hands the process a filtered one. The
// install-scope switch is offered only to such accounts: another account's
// credentials would make Setup's HKCU the wrong hive.
bool IsAdminAccount();

enum class ApplyResult {
  kLaunched,   // installer running; the caller must exit now
  kCancelled,  // the user declined the elevation prompt; nothing changed
  kRejected,   // signature / launch failure; nothing changed
};

// Verify the staged installer's detached Ed25519 signature against the
// embedded release public key; on success strip the Mark-of-the-Web and
// launch the installer silently WHILE THIS PROCESS STILL RUNS with the mode
// flag for [target] (see install_scope.h). Elevation (the runas verb) is
// requested only when a machine scope is involved, so the prompt appears
// first: declining it leaves the app running (kCancelled). On consent the
// installer waits for this process id to exit (its /PID parameter, see
// windows/installer/glimpr.iss) before replacing files, then relaunches
// the app un-elevated.
ApplyResult ApplyStaged(const std::wstring& exe_path,
                        const std::wstring& sig_path,
                        install_scope::Target target);

}  // namespace update_installer

#endif  // RUNNER_UPDATE_INSTALLER_H_
