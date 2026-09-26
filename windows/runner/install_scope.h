#ifndef RUNNER_INSTALL_SCOPE_H_
#define RUNNER_INSTALL_SCOPE_H_

#include <string>

// Install scope of the Inno-installed copy and the rules for launching the
// installer with the matching mode. Header-only so the native tests cover
// it without linking the registry / shell code in update_installer.cpp.
namespace install_scope {

// Where THIS copy is installed (from the uninstall registry key that names
// the exe directory as InstallLocation). kNone = portable / dev tree.
enum class Scope { kNone, kMachine, kUser };

// What an apply asks for: keep the current scope (an update) or move to
// the named scope (the Settings > Advanced switch).
enum class Target { kKeep, kMachine, kUser };

inline Scope Effective(Scope current, Target target) {
  switch (target) {
    case Target::kMachine:
      return Scope::kMachine;
    case Target::kUser:
      return Scope::kUser;
    case Target::kKeep:
    default:
      return current;
  }
}

// The installer must run elevated whenever a machine scope is involved:
// installing into Program Files, or removing the machine copy while
// moving to the per-user scope. A per-user update touches nothing that
// needs administrator rights.
inline bool NeedsElevation(Scope current, Scope effective) {
  return current == Scope::kMachine || effective == Scope::kMachine;
}

// Silent-run parameters for the installer: the /PID handshake plus the
// explicit mode flag, so Setup never has to guess the scope.
inline std::wstring InstallerParams(Scope effective, unsigned long pid) {
  std::wstring p = L"/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /PID=";
  p += std::to_wstring(pid);
  p += effective == Scope::kMachine ? L" /ALLUSERS" : L" /CURRENTUSER";
  return p;
}

inline const char* ScopeName(Scope s) {
  switch (s) {
    case Scope::kMachine:
      return "machine";
    case Scope::kUser:
      return "user";
    case Scope::kNone:
    default:
      return "";
  }
}

inline Target TargetFromString(const std::string& s) {
  if (s == "machine") return Target::kMachine;
  if (s == "user") return Target::kUser;
  return Target::kKeep;
}

}  // namespace install_scope

#endif  // RUNNER_INSTALL_SCOPE_H_
