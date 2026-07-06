import 'dart:io' as io;

import 'package:flutter/foundation.dart';

/// Test seam over `dart:io` Platform's OS checks. Production code reads
/// [platformIsWindows] / [platformIsMacOS] instead of `Platform.isX` so tests
/// can exercise the other platform's branches on any host. Only the OS FLAG is
/// faked — `Platform.environment`, path separators etc. stay real.
@visibleForTesting
TargetPlatform? debugPlatformOverride;

bool get platformIsWindows => debugPlatformOverride != null
    ? debugPlatformOverride == TargetPlatform.windows
    : io.Platform.isWindows;

bool get platformIsMacOS => debugPlatformOverride != null
    ? debugPlatformOverride == TargetPlatform.macOS
    : io.Platform.isMacOS;
