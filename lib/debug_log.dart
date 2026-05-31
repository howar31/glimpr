import 'dart:io';

/// Temporary debug file logger — appends to /tmp/glimpr-debug.log with flush so
/// it survives stdout buffering and captures output from EVERY Flutter engine
/// (the per-display overlay engines are not streamed by `flutter run`). Remove
/// after the Phase 2 overlay is verified.
void glog(String s) {
  try {
    File('/tmp/glimpr-debug.log')
        .writeAsStringSync('[dart] $s\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}
