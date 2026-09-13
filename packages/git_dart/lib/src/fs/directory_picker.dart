/// Bringing a folder the user already has into a [MemoryGitFs].
///
/// The browser counterpart to opening a folder on the desktop. A repository
/// someone cloned or built with real git, sitting on their own disk, is not
/// reachable from a page at all except through a picker the user drives
/// themselves — there is no path a script can simply open. `showDirectoryPicker`
/// is that picker: it hands back a handle to whatever folder was chosen, which
/// this reads recursively, dotfiles included, so `.git` comes along with
/// everything else.
///
/// Read-only by design. What comes out of the picker is copied into memory
/// once and then left alone; nothing here writes back to the folder the user
/// picked; a change made on the site is saved to OPFS, the way anything else
/// on this platform is (`fs.opfs-store`).
library;

import 'directory_picker_unavailable.dart'
    if (dart.library.js_interop) 'directory_picker_web.dart' as impl;
import 'memory_git_fs.dart';

/// Whether this platform can offer the picker at all.
///
/// Chromium only, as of when this was written — Firefox and Safari have not
/// implemented `showDirectoryPicker`. A caller should check before offering
/// the option, rather than let the picker call fail unexplained.
Future<bool> get canPickDirectory => impl.isAvailable();

/// Asks the user to pick a folder, and copies everything in it into [memory].
///
/// [placeAt] is given the folder's own name — not known until the user has
/// chosen it — and returns where to write it; that is what lets a caller
/// decide the destination itself, including resolving a name that collides
/// with something already there, without this needing to know anything about
/// how paths in [memory] are organised.
///
/// Returns the path written to, or null when the user cancelled the picker.
/// [memory] is untouched in that case.
Future<String?> pickDirectoryInto(
  MemoryGitFs memory,
  String Function(String folderName) placeAt,
) =>
    impl.pickDirectoryInto(memory, placeAt);
