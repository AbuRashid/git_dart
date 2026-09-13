/// What bringing a picked folder into the workspace came to.
///
/// Its own file because both the facade and each platform's implementation
/// need the type: the facade to declare it in its signature, the web
/// implementation to construct one. Putting it in the facade file would make
/// the implementation import the facade that is conditionally importing it -
/// legal in Dart, but not worth the confusion when a third file avoids it.
library;

class ImportOutcome {
  /// Where it landed, and the name it was given - which may differ from what
  /// was picked, when that name was already taken.
  final String? path;
  final String? name;

  /// Why it was refused, when it was.
  final String? error;

  const ImportOutcome.success(this.path, this.name) : error = null;
  const ImportOutcome.failure(this.error)
      : path = null,
        name = null;

  bool get succeeded => error == null;
}
