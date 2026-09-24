#ifndef RUNNER_EDITOR_HOST_STATE_H_
#define RUNNER_EDITOR_HOST_STATE_H_

#include <string>

// The main-process view of the editor host child, as a pure state machine so
// the native tests pin its rules. The client (editor_host_client.cpp) owns the
// pipes and processes and asks the machine what to do on each event.
namespace ehstate {

enum class State { kNone, kSpawning, kOpen, kEnding };

struct Pending {
  enum Kind { kNoneKind, kReveal, kPath, kClipboard };
  Kind kind = kNoneKind;
  std::string path;
};

struct Machine {
  enum class Action { kNone, kSpawn, kSend, kSendPending, kDropPending };

  State state = State::kNone;
  Pending pending;
  bool said_bye = false;

  // An open request (reveal / load a path / load the clipboard).
  Action OnRequest(Pending::Kind kind, const std::string& path) {
    if (state == State::kOpen) return Action::kSend;
    // Hold the request for READY. A plain reveal never downgrades a stored
    // load; a newer load replaces an older one.
    if (kind != Pending::kReveal || pending.kind == Pending::kNoneKind) {
      pending.kind = kind;
      pending.path = path;
    }
    return state == State::kNone ? Action::kSpawn : Action::kNone;
  }

  Action OnSpawned(bool ok) {
    if (ok) {
      state = State::kSpawning;
      return Action::kNone;
    }
    state = State::kNone;
    pending = Pending{};
    return Action::kDropPending;
  }

  Action OnReady() {
    state = State::kOpen;
    if (pending.kind == Pending::kNoneKind) return Action::kNone;
    return Action::kSendPending;  // the caller reads + clears pending
  }

  Action OnBye() {
    said_bye = true;
    state = State::kEnding;
    return Action::kNone;
  }

  // Pipe EOF: the child is gone (after BYE, or crashed).
  Action OnExit() {
    state = State::kNone;
    return pending.kind == Pending::kNoneKind ? Action::kNone : Action::kSpawn;
  }
};

}  // namespace ehstate

#endif  // RUNNER_EDITOR_HOST_STATE_H_
