import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../config/git_config.dart';
import '../diff/text_diff.dart';
import '../fs/git_fs.dart';

/// What one `.gitattributes` line says about the paths it matches.
class AttributeRule {
  final RegExp matcher;

  /// The directory the rule was written in, relative to the working tree root.
  final String base;

  /// Attribute name to its value: `true` set, `false` unset, `null`
  /// unspecified, or a string for `key=value`.
  final Map<String, Object?> attributes;

  final String source;

  const AttributeRule({
    required this.matcher,
    required this.base,
    required this.attributes,
    required this.source,
  });

  @override
  String toString() => source;
}

/// How a file's line endings are stored and written out.
enum EolConversion {
  /// Left exactly as it is, in both directions. What git does for anything it
  /// decides is binary, and the only setting that cannot corrupt a file.
  none,

  /// CRLF becomes LF on the way in, and LF becomes CRLF on the way out.
  crlf,

  /// CRLF becomes LF on the way in, and nothing changes on the way out.
  lf,
}

/// The attributes in force for a working tree.
///
/// Git stores text with LF endings and converts on the way in and out, so that
/// a repository shared between systems that disagree about line endings holds
/// one answer rather than both. Nothing about this is visible in the object
/// model: the blob is the converted form, so two working trees that look
/// different are byte-for-byte the same object, and two that look the same can
/// be different objects. Getting it wrong therefore shows up as a repository
/// where every file is modified and no change was made.
class Attributes {
  final List<AttributeRule> rules = [];

  /// `core.autocrlf`, which applies where no attribute says otherwise.
  final String autocrlf;

  /// `core.eol`, the working-tree ending for text files when `autocrlf` is
  /// not deciding.
  final String eol;

  Attributes({this.autocrlf = 'false', this.eol = 'native'});

  void addFile(String path, {String base = ''}) {
    final file = fs.file(path);
    if (!file.existsSync()) return;
    addText(file.readAsStringSync(), base: base);
  }

  void addText(String text, {String base = ''}) {
    for (final line in LineSplitter.split(text)) {
      final rule = _compile(line, base);
      if (rule != null) rules.add(rule);
    }
  }

  /// Every attribute that applies to [path], later rules winning.
  Map<String, Object?> forPath(String path) {
    final out = <String, Object?>{};
    for (final rule in rules) {
      if (rule.base.isNotEmpty && !path.startsWith('${rule.base}/')) continue;
      final relative = rule.base.isEmpty
          ? path
          : path.substring(rule.base.length + 1);
      if (!rule.matcher.hasMatch(relative)) continue;
      out.addAll(rule.attributes);
    }
    return out;
  }

  /// Whether [path] is treated as text, or null when nothing has said and the
  /// content has to decide.
  ///
  /// `-text` and `binary` mean no; `text` means yes; `text=auto` means "look
  /// at the content", which is the same answer as saying nothing except that
  /// it also overrides `core.autocrlf` being off.
  bool? isText(String path) {
    final attributes = forPath(path);
    final text = attributes['text'];
    if (text == false) return false;
    if (text == 'auto') return null;
    if (text == true) return true;
    return null;
  }

  /// How [path]'s endings are converted, given what the attributes and the
  /// config say and what the content looks like.
  ///
  /// [content] decides only when nothing else has: git will not convert a file
  /// that holds a NUL byte, whatever it has been told, because doing so
  /// corrupts it and the mistake is unrecoverable.
  EolConversion conversionFor(String path, Uint8List content) {
    final attributes = forPath(path);

    if (attributes['binary'] == true || attributes['text'] == false) {
      return EolConversion.none;
    }

    final declared = attributes['eol'];
    final marked = attributes['text'];

    // An explicit `eol` wins over everything, but never over binary content.
    if (declared == 'crlf' || declared == 'lf') {
      if (looksBinary(content)) return EolConversion.none;
      return declared == 'crlf' ? EolConversion.crlf : EolConversion.lf;
    }

    final isTextByContent = !looksBinary(content);

    // `text` set explicitly: convert even if the content is unusual — except
    // when it holds a NUL, where converting would corrupt it.
    if (marked == true) {
      if (looksBinary(content)) return EolConversion.none;
      return _fromConfig();
    }

    // `text=auto`, or nothing said at all.
    if (marked == 'auto') {
      return isTextByContent ? _fromConfig() : EolConversion.none;
    }

    // Nothing said. Only `core.autocrlf` can turn conversion on now.
    if (autocrlf == 'true' || autocrlf == 'input') {
      return isTextByContent ? _fromConfig() : EolConversion.none;
    }
    return EolConversion.none;
  }

  EolConversion _fromConfig() {
    // `input` means convert on the way in and leave the working tree alone,
    // which is what a system with LF endings wants when it shares a repository
    // with one that does not.
    if (autocrlf == 'input') return EolConversion.lf;
    if (autocrlf == 'true') return EolConversion.crlf;
    if (eol == 'crlf') return EolConversion.crlf;
    if (eol == 'lf') return EolConversion.lf;
    // `native`, which is what the platform does.
    return Platform.isWindows ? EolConversion.crlf : EolConversion.lf;
  }

  static AttributeRule? _compile(String line, String base) {
    var text = line.trim();
    if (text.isEmpty || text.startsWith('#')) return null;

    // A pattern, then space-separated attributes.
    final parts = text.split(RegExp(r'\s+'));
    final pattern = parts.first;
    final attributes = <String, Object?>{};

    for (final token in parts.skip(1)) {
      if (token.isEmpty) continue;
      if (token.startsWith('-')) {
        attributes[token.substring(1)] = false;
      } else if (token.startsWith('!')) {
        attributes[token.substring(1)] = null;
      } else {
        final equals = token.indexOf('=');
        if (equals < 0) {
          attributes[token] = true;
        } else {
          attributes[token.substring(0, equals)] = token.substring(equals + 1);
        }
      }
    }

    // `binary` is shorthand git expands to `-diff -merge -text`.
    if (attributes['binary'] == true) {
      attributes['text'] = false;
      attributes['diff'] = false;
      attributes['merge'] = false;
    }

    if (attributes.isEmpty) return null;

    var glob = pattern;
    final anchored = glob.contains('/') && !glob.endsWith('/');
    if (glob.startsWith('/')) glob = glob.substring(1);

    final expression = StringBuffer(anchored ? '^' : r'^(.*/)?')
      ..write(_translate(glob))
      ..write(r'(/.*)?$');

    return AttributeRule(
      matcher: RegExp(expression.toString()),
      base: base,
      attributes: attributes,
      source: line,
    );
  }

  /// The same glob translation `.gitignore` uses; the two formats share it.
  static String _translate(String glob) {
    final out = StringBuffer();
    var i = 0;
    while (i < glob.length) {
      final c = glob[i];
      switch (c) {
        case '*':
          if (i + 1 < glob.length && glob[i + 1] == '*') {
            i += 2;
            if (i < glob.length && glob[i] == '/') {
              out.write('(.*/)?');
              i += 1;
            } else {
              out.write('.*');
            }
            continue;
          }
          out.write('[^/]*');
        case '?':
          out.write('[^/]');
        case '[':
          final close = glob.indexOf(']', i + 1);
          if (close < 0) {
            out.write(r'\[');
          } else {
            var set = glob.substring(i + 1, close);
            if (set.startsWith('!')) set = '^${set.substring(1)}';
            out.write('[$set]');
            i = close;
          }
        default:
          out.write(RegExp.escape(c));
      }
      i += 1;
    }
    return out.toString();
  }
}

// Whether content should be left alone is decided by `looksBinary` in the
// diff layer: a NUL in the first few thousand bytes, which is git's own test
// and is a heuristic rather than a fact. The same question is asked of the
// same bytes in both places, so it is answered in one.

/// The bytes to store for [content] read from the working tree.
///
/// Converting to LF on the way in is what makes the stored object the same
/// whichever system wrote it.
Uint8List toStorage(Uint8List content, EolConversion conversion) {
  if (conversion == EolConversion.none) return content;
  return _toLf(content);
}

/// The bytes to write into the working tree for a stored [content].
Uint8List toWorkingTree(Uint8List content, EolConversion conversion) {
  if (conversion != EolConversion.crlf) return content;
  return _toCrlf(content);
}

Uint8List _toLf(Uint8List content) {
  // Only CR immediately before LF is removed. A lone CR is content — old Mac
  // text, or a progress bar in a log — and dropping it would change a file
  // nobody asked to change.
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < content.length; i++) {
    if (content[i] == 0x0d &&
        i + 1 < content.length &&
        content[i + 1] == 0x0a) {
      continue;
    }
    out.addByte(content[i]);
  }
  return out.takeBytes();
}

Uint8List _toCrlf(Uint8List content) {
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < content.length; i++) {
    // An LF that already has a CR before it is left alone, so that converting
    // twice is the same as converting once.
    if (content[i] == 0x0a && (i == 0 || content[i - 1] != 0x0d)) {
      out.addByte(0x0d);
    }
    out.addByte(content[i]);
  }
  return out.takeBytes();
}

/// The attributes for a working tree: the repository's own, then the ones git
/// keeps outside it.
///
/// The order is the order of precedence, weakest first, because [Attributes]
/// lets later rules win.
Attributes loadAttributes(
  String workTree,
  String gitDirectory, {
  GitConfig? config,
}) {
  final settings = config ?? GitConfig.forRepository(gitDirectory);

  final attributes = Attributes(
    autocrlf: (settings['core.autocrlf'] ?? 'false').toLowerCase(),
    eol: (settings['core.eol'] ?? 'native').toLowerCase(),
  );

  final configured = settings['core.attributesfile'];
  if (configured != null && configured.isNotEmpty) {
    attributes.addFile(GitConfig.expandHome(configured));
  }

  return attributes
    ..addFile(p.join(gitDirectory, 'info', 'attributes'))
    ..addFile(p.join(workTree, '.gitattributes'));
}
