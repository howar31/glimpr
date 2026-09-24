#ifndef RUNNER_EDITOR_HOST_H_
#define RUNNER_EDITOR_HOST_H_

// Entry point for the editor host process (glimpr.exe --editor-host
// --main-pid=<pid> [--placement=<base64>]). main() routes here before the
// single-instance guard.
//
// The host owns the Image Editor window + its Flutter engine and everything
// the editor touches natively (clipboard, encode, sound, fonts, the OLE drop
// target). It exists so the editor costs nothing while closed: a Flutter
// engine that has rendered never returns its GPU memory when destroyed
// in-process (flutter/flutter#193080), so the main process spawns a host on
// the first open request and the host exits once the editor window has
// closed and its deferred work has drained (editor_exit_gate.h).
//
// Pipe protocol (overlay_ipc.h): commands arrive on stdin as CALL lines
// (reveal, loadPath, loadClipboard, clearRecent, refreshRecent); events leave
// on stdout (READY, CALL <setRecentImages|pinImage|setProcessing|openSettings|
// placement>, PERF, BYE). stdin EOF means the main process is gone or wants
// the host gone: exit at once.
int EditorHostMain();

#endif  // RUNNER_EDITOR_HOST_H_
