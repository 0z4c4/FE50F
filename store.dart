import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Cache local en un unico JSON (velas cerradas, IDs de dedup, posicion simulada).
class Fe50fStore {
  static Future<File> _file() async {
    final d = await getApplicationSupportDirectory();
    return File('${d.path}/fe50f_state.json');
  }

  static Future<Map<String, dynamic>?> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(Map<String, dynamic> m) async {
    try {
      final f = await _file();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(m), flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  }
}
