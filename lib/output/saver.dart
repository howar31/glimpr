import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'filename.dart';

/// Writes [bytes] into [dir] (created recursively) as [fileName], never
/// overwriting an existing file. Returns the absolute path written.
Future<String> saveBytes({
  required Directory dir,
  required String fileName,
  required Uint8List bytes,
}) async {
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  final name = uniqueName(fileName,
      exists: (n) => File(p.join(dir.path, n)).existsSync());
  final file = File(p.join(dir.path, name));
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
