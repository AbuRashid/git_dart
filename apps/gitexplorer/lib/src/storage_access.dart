import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Talks to the Android side, which owns the permission and the settings screen.
const _channel = MethodChannel('gitexplorer/storage_access');

/// Whether reading a folder the user picked needs permission first.
///
/// Only Android gates it. Elsewhere a path the user chose in a file dialog is a
/// path the process can already read.
bool get storageAccessIsGated => !kIsWeb && Platform.isAndroid;

/// Whether the app can read files in the folders the user picks.
///
/// On Android this is "All files access". Scoped storage otherwise shows the app
/// only the files it created itself, which for a repository means the working
/// tree appears empty rather than failing outright — so this is checked before
/// picking, not diagnosed afterwards.
Future<bool> hasStorageAccess() async {
  if (!storageAccessIsGated) return true;
  return await _channel.invokeMethod<bool>('isGranted') ?? false;
}

/// Asks for storage access and reports what the user decided.
///
/// The grant cannot be given in a dialog: Android puts it behind a screen in
/// Settings, and the user comes back to us afterwards. The returned value is
/// therefore what is true on return, not what was asked for.
Future<bool> requestStorageAccess() async {
  if (!storageAccessIsGated) return true;
  return await _channel.invokeMethod<bool>('request') ?? false;
}
