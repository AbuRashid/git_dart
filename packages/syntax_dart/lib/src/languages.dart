import 'grammar.dart';
import 'grammars/clike.dart';
import 'grammars/dart.dart';
import 'grammars/json.dart';
import 'grammars/markdown.dart';
import 'grammars/python.dart';
import 'grammars/shell.dart';
import 'grammars/unimsg.dart';
import 'grammars/yaml.dart';

/// Every grammar this package ships, by name.
final Map<String, Grammar> grammars = {
  for (final grammar in <Grammar>[
    unimsgGrammar,
    dartGrammar,
    jsonGrammar,
    yamlGrammar,
    markdownGrammar,
    pythonGrammar,
    shellGrammar,
    ...clikeGrammars,
  ])
    grammar.name: grammar,
};

/// Which grammar a file name selects, or null for a type with no grammar —
/// in which case the file should be drawn plain rather than drawn wrong.
final Map<String, Grammar> _byExtension = {
  'umsg': unimsgGrammar,
  'dart': dartGrammar,
  'json': jsonGrammar,
  'jsonc': jsonGrammar,
  'yaml': yamlGrammar,
  'yml': yamlGrammar,
  'md': markdownGrammar,
  'markdown': markdownGrammar,
  'py': pythonGrammar,
  'pyi': pythonGrammar,
  'sh': shellGrammar,
  'bash': shellGrammar,
  'zsh': shellGrammar,
  for (final grammar in clikeGrammars)
    for (final extension in clikeExtensions[grammar.name]!) extension: grammar,
};

/// Files whose type is in their whole name rather than in an extension.
final Map<String, Grammar> _byName = {
  'dockerfile': shellGrammar,
  'makefile': shellGrammar,
  '.gitignore': shellGrammar,
  '.gitattributes': shellGrammar,
  '.bashrc': shellGrammar,
  '.zshrc': shellGrammar,
  '.profile': shellGrammar,
  'pubspec.lock': yamlGrammar,
  'license': markdownGrammar,
  'readme': markdownGrammar,
};

/// The grammar for [path], or null if none is known.
///
/// Takes a path rather than an extension because the answer sometimes needs
/// the whole file name — `Makefile` and `.gitignore` have no extension, and
/// `pubspec.lock` has one that means nothing.
Grammar? grammarForPath(String path) {
  final name = path.split(RegExp(r'[/\\]')).last.toLowerCase();
  final byName = _byName[name];
  if (byName != null) return byName;

  final dot = name.lastIndexOf('.');
  // A leading dot is the start of a hidden file, not an extension: `.gitignore`
  // has no extension, and treating `gitignore` as one would be an accident.
  if (dot <= 0) return null;
  return _byExtension[name.substring(dot + 1)];
}
