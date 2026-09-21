#ifndef RUNNER_OVERLAY_HOST_H_
#define RUNNER_OVERLAY_HOST_H_

// Entry point for the overlay host process (glimpr.exe --overlay-host
// --main-pid=<pid>). main() routes here before the single-instance guard.
//
// The host owns the per-display overlay windows + Flutter engines and
// everything they touch (freeze capture, HDR bases, loupe feeds, cursor,
// clipboard, encode, sound). It exists because a Flutter engine that has
// rendered never returns its GPU memory when destroyed in-process
// (flutter/flutter#193080): the host serves ONE capture session and then
// exits, so the OS reclaims everything, and the main process starts a fresh
// warm host for the next capture.
//
// Pipe protocol (overlay_ipc.h): commands arrive on stdin (BEGIN, RSHOTKEY),
// events leave on stdout (READY, ACK, CALL, PERF, BYE). stdin EOF means the main
// process is gone or wants the host gone: exit at once.
int OverlayHostMain();

#endif  // RUNNER_OVERLAY_HOST_H_
