/// A browser has no environment, no drive letters and no other processes.
const Map<String, String> environment = <String, String>{};

const bool isWindows = false;

const int processId = 0;

/// Nothing to clear: a browser has no read-only attribute, and no subprocess
/// to clear one with.
void clearReadOnlyUnder(String directory) {}
