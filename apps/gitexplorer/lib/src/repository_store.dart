import 'dart:convert';

import 'package:path/path.dart' as p;

import 'app_storage.dart';
import 'generated/tokens.dart';

/// One entry of the virtual root: a repository the user added.
class SavedRepository {
  /// The working tree path, absolute — what was picked.
  final String path;

  /// The display name. Renameable, because a folder name is often not the
  /// project's name.
  final String name;

  const SavedRepository({required this.path, required this.name});

  factory SavedRepository.forPath(String path) => SavedRepository(
        path: path,
        name: p.basename(p.normalize(path)),
      );

  Map<String, Object?> toJson() => {'path': path, 'name': name};

  static SavedRepository? fromJson(Object? json) {
    if (json is! Map) return null;
    final path = json['path'];
    if (path is! String || path.isEmpty) return null;
    final name = json['name'];
    return SavedRepository(
      path: path,
      name: name is String && name.isNotEmpty
          ? name
          : p.basename(p.normalize(path)),
    );
  }
}

/// What survives a restart: the arrangement, and how it is drawn.
class SavedState {
  final List<SavedRepository> repositories;
  final ThemeChoice theme;

  const SavedState({
    this.repositories = const [],
    this.theme = ThemeChoice.system,
  });

  SavedState copyWith({
    List<SavedRepository>? repositories,
    ThemeChoice? theme,
  }) =>
      SavedState(
        repositories: repositories ?? this.repositories,
        theme: theme ?? this.theme,
      );
}

/// The list of repositories, kept between sessions.
///
/// The arrangement is the only thing here that is not derivable from disk, so
/// it is the only thing saved — and a path that has gone missing stays in the
/// list rather than being dropped, because losing a user's arrangement to an
/// unmounted drive is worse than showing a row that says it is unavailable
/// (`persistence.a-missing-repository-is-kept`).
class RepositoryStore {
  static const fileName = 'repositories.json';

  /// Injectable so a test does not write into the real support directory.
  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;

  RepositoryStore({
    Future<String?> Function(String key)? read,
    Future<void> Function(String key, String value)? write,
  })  : _read = read ?? readAppSetting,
        _write = write ?? writeAppSetting;

  /// Everything remembered between sessions.
  Future<SavedState> load() async {
    final text = await _read(fileName);
    if (text == null || text.isEmpty) return const SavedState();

    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return const SavedState();
      final version = decoded['version'];
      if (version is int && version > persistedStateVersion) {
        // A newer version is a shape this build does not know. Reading it as
        // though it were this one would quietly discard whatever was added.
        throw StateError(
          'the saved repository list is version $version and this build '
          'understands $persistedStateVersion',
        );
      }
      final saved = decoded['repositories'];
      return SavedState(
        repositories: [
          if (saved is List)
            for (final entry in saved)
              if (SavedRepository.fromJson(entry) case final repository?)
                repository,
        ],
        // An absent or unrecognised choice takes the default rather than
        // failing: the version guards a change of shape, not an addition to
        // it (`persistence.an-unknown-key-is-ignored`).
        theme: _themeFromJson(decoded['theme']),
      );
    } on FormatException {
      // A corrupt file is not worth failing the application over; the list is
      // rebuildable by the user in seconds.
      return const SavedState();
    }
  }

  static ThemeChoice _themeFromJson(Object? value) {
    for (final choice in ThemeChoice.values) {
      if (choice.name == value) return choice;
    }
    return ThemeChoice.system;
  }

  Future<void> save(SavedState state) => _write(
        fileName,
        jsonEncode({
          'version': persistedStateVersion,
          'repositories': [for (final r in state.repositories) r.toJson()],
          'theme': state.theme.name,
        }),
      );
}
