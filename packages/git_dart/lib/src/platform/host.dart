/// The few facts about the host that git's behaviour depends on.
///
/// Three of them, and each one is a place where a browser has no answer:
/// where the user's home directory is, whether this is Windows, and which
/// process this is. `dart:io` answers all three and throws
/// `Unsupported operation: Platform._environment` on the web — from inside
/// a config lookup, which is a long way from anything the caller did.
///
/// The web answers are chosen so that the code above carries on rather than
/// branching: no environment means no global config and no global excludes,
/// which is exactly right for a browser; not-Windows means LF line endings by
/// default and no executable-bit workarounds; and a process id of zero only
/// ever has to be unique among processes sharing a filesystem, of which there
/// are none.
library;

import 'host_io.dart' if (dart.library.js_interop) 'host_web.dart' as impl;

/// The process environment, or empty where there is none.
Map<String, String> get environment => impl.environment;

/// Whether this is Windows, which decides the native line ending and whether
/// the executable bit means anything.
bool get isWindows => impl.isWindows;

/// This process, used only to keep temporary filenames from colliding between
/// processes sharing a repository.
int get processId => impl.processId;

/// The user's home directory, by whichever name this platform gives it, or
/// null where there is none.
String? get homeDirectory =>
    environment['HOME'] ?? environment['USERPROFILE'];
