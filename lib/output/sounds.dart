import 'package:audioplayers/audioplayers.dart';

/// Capture feedback sounds. The shutter fires at the instant the capture is
/// committed (crop release / window snap); the completion chime fires after the
/// background save + clipboard finish successfully. Separate players so the two
/// never cut each other off.
final AudioPlayer _shutter = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
final AudioPlayer _complete = AudioPlayer()..setReleaseMode(ReleaseMode.stop);

/// Camera-shutter click — at the moment of capture.
Future<void> playShutter() => _shutter.play(AssetSource('sounds/shutter.wav'));

/// Soft ascending two-note chime — once the capture is fully delivered.
Future<void> playComplete() =>
    _complete.play(AssetSource('sounds/complete.wav'));
