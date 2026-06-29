#ifndef RUNNER_RECORD_WORKER_H_
#define RUNNER_RECORD_WORKER_H_

// Entry point for the screen-recording worker process (glimpr.exe
// --record-worker). main() routes here before the single-instance guard and
// Flutter init when the command line carries --record-worker. The worker hosts
// the real Recorder (WGC + Media Foundation + WASAPI) in its OWN process, so a
// capture/encode crash kills only the worker and never the main app. It reads
// the RecordSpec from argv, sends lifecycle events on stdout, and takes
// pause/resume/stop/abort commands on stdin. Returns the process exit code.
int RecordWorkerMain();

#endif  // RUNNER_RECORD_WORKER_H_
