import 'dart:io';

import 'package:flutter/foundation.dart';

final String buildCommit = _readBuildCommit();

String _readBuildCommit() {
  const hash = String.fromEnvironment('GIT_HASH');
  if (hash.isNotEmpty) return hash;

  if (!kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
    try {
      final result = Process.runSync('git', ['rev-parse', '--short', 'HEAD']);
      final output = (result.stdout as String).trim();
      if (result.exitCode == 0 && output.isNotEmpty) return output;
    } on ProcessException {
      // A packaged build may run outside a Git checkout.
    }
  }
  return 'Unknown commit';
}
