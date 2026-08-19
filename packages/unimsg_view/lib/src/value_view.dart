import 'package:flutter/material.dart';
import 'package:unimsg/unimsg.dart' as u;

import 'document_view.dart';
import 'notes.dart';
import 'palette.dart';
import 'shape.dart';

/// One value, drawn as whatever [treatmentOf] says it is.
///
/// Every branch below is a Material component doing the job it exists for: a
/// table is a table, a magnitude is a progress bar, a disclosure is an
/// expansion tile. Rebuilding those out of boxes and borders would produce
/// something that looked like this window and behaved like nothing on the
/// machine — no keyboard handling, no density, no ink.
class ValueView extends StatelessWidget {
  final u.UValue value;

  /// Where this sits in the document, so a reference can name it.
  final String path;

  const ValueView({super.key, required this.value, required this.path});

  @override
  Widget build(BuildContext context) {
    final scope = DocumentScope.of(context);
    switch (treatmentOf(value)) {
      case Treatment.table:
        return _TableView(value: bare(value) as u.USeq, path: path);
      case Treatment.entries:
        return _EntriesView(map: bare(value) as u.UMap, path: path);
      case Treatment.outline:
        return _OutlineView(map: bare(value) as u.UMap, path: path);
      case Treatment.glossary:
        return _GlossaryView(map: bare(value) as u.UMap, path: path);
      case Treatment.settings:
        return _SettingsView(map: bare(value) as u.UMap, path: path);
      case Treatment.breakdown:
        return _BreakdownView(map: bare(value) as u.UMap);
      case Treatment.chips:
        return _ChipsView(items: (bare(value) as u.USeq).values);
      case Treatment.prose:
        return ProseView(text: (bare(value) as u.UText).value);
      case Treatment.fields:
        final inner = bare(value);
        if (inner is u.UMap) return FieldsView(entries: inner.entries, path: path);
        if (inner is u.USeq) return _MixedSeqView(items: inner.values, path: path);
        return scalarText(context, value, scope.palette);
      case Treatment.scalar:
        return scalarText(context, value, scope.palette);
    }
  }
}

// ---------------------------------------------------------------------------
// scalars
// ---------------------------------------------------------------------------

/// One value on one line, coloured by what it is.
///
/// A reference is the only kind that is also a control, because it is the only
/// kind that leads anywhere. The rest are text, and are selectable rather than
/// tappable.
Widget scalarText(BuildContext context, u.UValue value, UnimsgPalette palette) {
  final theme = Theme.of(context);
  final v = bare(value);
  final annotations = annotationsOf(value);

  Widget body;
  if (v is u.UReference) {
    body = _ReferenceLink(name: v.name);
  } else {
    body = Text(
      scalarLabel(v),
      style: theme.textTheme.bodyMedium?.copyWith(
        color: scalarColor(v, palette),
        fontFamily: _monospaced(v) ? 'monospace' : null,
      ),
    );
  }

  if (annotations.isEmpty) return body;
  return Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 6,
    children: [
      for (final annotation in annotations)
        Text(
          annotation is u.IdentifierAnnotation
              ? '@${annotation.name}'
              : ':${annotation.name}',
          style: theme.textTheme.labelMedium?.copyWith(color: palette.meta),
        ),
      body,
    ],
  );
}

/// How a value reads on a line. Sigils are kept: `:draft` and `draft` are
/// different things, and a page that drops the colon has said the wrong one.
String scalarLabel(u.UValue value) {
  final v = bare(value);
  return switch (v) {
    u.UNull() => 'null',
    u.UBool(:final value) => value ? 'true' : 'false',
    u.UInt(:final value) => value.toString(),
    u.UFloat(:final value) => '${value}f',
    u.UDecimal() => _decimal(v),
    u.UText(:final value) => value,
    u.USymbol(:final name) => ':$name',
    u.UIdentifier(:final name) => '@$name',
    u.UReference(:final name) => '-> @$name',
    u.UTimestamp(:final text) => text,
    u.UHash(:final algorithm, :final digest) => '#$algorithm:${_hex(digest)}',
    u.UBytes(:final value) => '~hex:${_hex(value)}',
    u.UExtension(:final name) => '!$name',
    u.UTagged(:final tag) => 'tag $tag',
    u.UMap() || u.USeq() || u.UAnnotated() => '',
  };
}

Color scalarColor(u.UValue value, UnimsgPalette palette) => switch (bare(value)) {
      u.UText() => palette.text,
      u.USymbol() || u.UBool() || u.UNull() => palette.atom,
      u.UIdentifier() || u.UReference() || u.UHash() || u.UBytes() ||
      u.UExtension() =>
        palette.meta,
      u.UInt() || u.UFloat() || u.UDecimal() || u.UTimestamp() =>
        palette.number,
      _ => palette.text,
    };

/// Digests and byte strings are read a character at a time, and comparing two
/// of them by eye needs the columns to line up.
bool _monospaced(u.UValue value) =>
    value is u.UHash || value is u.UBytes || value is u.UTimestamp;

String _decimal(u.UValue value) {
  final v = value as u.UDecimal;
  final exponent = v.exponent.toInt();
  final digits = v.mantissa.abs().toString();
  if (exponent >= 0) return '${v.mantissa}${'0' * exponent}';
  final sign = v.mantissa.isNegative ? '-' : '';
  final padded = digits.padLeft(-exponent + 1, '0');
  final split = padded.length + exponent;
  return '$sign${padded.substring(0, split)}.${padded.substring(split)}';
}

String _hex(List<int> bytes) {
  final shown = bytes.take(8);
  final text = [
    for (final byte in shown) byte.toRadixString(16).padLeft(2, '0'),
  ].join();
  return bytes.length > 8 ? '$text…' : text;
}

/// A reference, which the format says is inert until something resolves it.
///
/// Resolved, it is a link. Unresolved, it is still shown — the document said
/// it points somewhere — and it stops offering a tap that would go nowhere. A
/// link that leads nowhere is worse than no link, because finding that out
/// costs a click.
class _ReferenceLink extends StatelessWidget {
  final String name;
  const _ReferenceLink({required this.name});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = DocumentScope.of(context);
    final target = scope.anchors.resolve(name);

    if (target == null) {
      return Tooltip(
        message: 'not declared in this document',
        child: Text(
          '-> @$name',
          style: theme.textTheme.bodyMedium?.copyWith(color: scope.palette.quiet),
        ),
      );
    }

    return InkWell(
      onTap: () => scope.goTo(target),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(
          '-> @$name',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.primary,
            decoration: TextDecoration.underline,
            decorationColor: theme.colorScheme.primary.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// prose
// ---------------------------------------------------------------------------

/// Text long enough to be read, reflowed to the reader's column.
///
/// Backticks are drawn as code and nothing more. They were nearly made into
/// links, until the corpus was asked: of eighty-one backticked names across
/// eighteen documents, fifteen named something the document declares. The
/// rest are `main`, `author`, `user.email` — code, not cross-references. A
/// link that is wrong four times in five teaches a reader to stop trying.
class ProseView extends StatelessWidget {
  final String text;
  const ProseView({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = DocumentScope.of(context).palette;
    final paragraphs = readNote([text]).paragraphs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final paragraph in paragraphs)
          Padding(
            padding: EdgeInsets.only(
              bottom: paragraph == paragraphs.last ? 0 : 10,
            ),
            child: Text.rich(
              TextSpan(
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                children: [
                  for (final fragment in fragments(paragraph))
                    TextSpan(
                      text: fragment.text,
                      style: fragment.isCode
                          ? theme.textTheme.bodyMedium?.copyWith(
                              fontFamily: 'monospace',
                              color: palette.name,
                              height: 1.5,
                            )
                          : null,
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// collections
// ---------------------------------------------------------------------------

/// Key and value, one pair to a row. The shape everything falls back to.
class FieldsView extends StatelessWidget {
  final List<u.MapEntry> entries;
  final String path;

  const FieldsView({super.key, required this.entries, required this.path});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in entries)
          _Field(entry: entry, path: _join(path, entry.key)),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  final u.MapEntry entry;
  final String path;

  const _Field({required this.entry, required this.path});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = DocumentScope.of(context);
    final note = readNote(entry.comments);
    final block = !isInline(entry.value);

    final label = Text(
      entry.key,
      style: theme.textTheme.labelLarge?.copyWith(color: scope.palette.name),
    );
    final body = ValueView(value: entry.value, path: path);

    return Padding(
      key: scope.keyFor(path),
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!note.isEmpty) NoteView(note: note),
          if (block) ...[
            label,
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: body,
            ),
          ] else
            // A value that fits on a line sits beside its key, and the keys
            // line up so the column can be read on its own.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 180, child: label),
                const SizedBox(width: 12),
                Expanded(child: body),
              ],
            ),
        ],
      ),
    );
  }
}

/// A keyed collection: each entry is a thing of the same kind, so each gets a
/// card of its own.
class _EntriesView extends StatelessWidget {
  final u.UMap map;
  final String path;

  const _EntriesView({required this.map, required this.path});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = DocumentScope.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in map.entries)
          Card(
            key: scope.keyFor(_join(path, entry.key)),
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.key, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  ValueView(
                    value: entry.value,
                    path: _join(path, entry.key),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A hierarchy rather than a list of siblings: deep and narrow, where cards
/// inside cards inside cards stop being readable.
class _OutlineView extends StatelessWidget {
  final u.UMap map;
  final String path;

  const _OutlineView({required this.map, required this.path});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = DocumentScope.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in map.entries)
          Padding(
            key: scope.keyFor(_join(path, entry.key)),
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.key,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: scope.palette.name),
                ),
                Container(
                  margin: const EdgeInsets.only(left: 6, top: 4),
                  padding: const EdgeInsets.only(left: 12),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: theme.dividerColor),
                    ),
                  ),
                  child: ValueView(
                    value: entry.value,
                    path: _join(path, entry.key),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Terms and their definitions.
class _GlossaryView extends StatelessWidget {
  final u.UMap map;
  final String path;

  const _GlossaryView({required this.map, required this.path});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = DocumentScope.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in map.entries)
          Padding(
            key: scope.keyFor(_join(path, entry.key)),
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.comments.isNotEmpty)
                  NoteView(note: readNote(entry.comments)),
                Text(
                  entry.key,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: scope.palette.name),
                ),
                const SizedBox(height: 4),
                ProseView(text: (bare(entry.value) as u.UText).value),
              ],
            ),
          ),
      ],
    );
  }
}

/// Plain values, aligned so the column can be read down.
class _SettingsView extends StatelessWidget {
  final u.UMap map;
  final String path;

  const _SettingsView({required this.map, required this.path});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = DocumentScope.of(context);

    return Table(
      columnWidths: const {
        0: IntrinsicColumnWidth(),
        1: FlexColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        for (final entry in map.entries)
          TableRow(
            children: [
              Padding(
                key: scope.keyFor(_join(path, entry.key)),
                padding: const EdgeInsets.only(right: 20, bottom: 6),
                child: Text(
                  entry.key,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: scope.palette.name),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: scalarText(context, entry.value, scope.palette),
              ),
            ],
          ),
      ],
    );
  }
}

/// Comparable magnitudes.
///
/// The bar is Material's own progress indicator, which already knows how to
/// draw a proportion at this theme's density and colour. Bars are relative to
/// the largest value present, and the number is shown beside each: a bar says
/// which is bigger at a glance and the figure says by how much.
class _BreakdownView extends StatelessWidget {
  final u.UMap map;
  const _BreakdownView({required this.map});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = DocumentScope.of(context).palette;
    final numbers = [
      for (final entry in map.entries) asNumber(entry.value) ?? 0,
    ];
    final largest = numbers.reduce((a, b) => a > b ? a : b);

    return Column(
      children: [
        for (var i = 0; i < map.entries.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 160,
                  child: Text(
                    map.entries[i].key,
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: palette.name),
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: largest == 0 ? 0 : numbers[i] / largest,
                      minHeight: 8,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 84,
                  child: Text(
                    scalarLabel(map.entries[i].value),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: palette.number),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A set of small values.
class _ChipsView extends StatelessWidget {
  final List<u.UValue> items;
  const _ChipsView({required this.items});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = DocumentScope.of(context).palette;
    if (items.isEmpty) {
      return Text('empty', style: theme.textTheme.bodyMedium
          ?.copyWith(color: palette.quiet, fontStyle: FontStyle.italic));
    }

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final item in items)
          Chip(
            label: Text(scalarLabel(item)),
            labelStyle: theme.textTheme.labelMedium
                ?.copyWith(color: scalarColor(item, palette)),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            side: BorderSide(color: theme.dividerColor),
            backgroundColor: theme.colorScheme.surfaceContainerLow,
          ),
      ],
    );
  }
}

/// A sequence holding collections: numbered, because position is the only
/// name an item of a sequence has.
class _MixedSeqView extends StatelessWidget {
  final List<u.UValue> items;
  final String path;

  const _MixedSeqView({required this.items, required this.path});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = DocumentScope.of(context).palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 28,
                  child: Text(
                    '${i + 1}',
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: palette.quiet),
                  ),
                ),
                Expanded(
                  child: ValueView(value: items[i], path: '$path.$i'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// tables
// ---------------------------------------------------------------------------

/// A sequence of maps with the same keys.
///
/// Flutter's [Table] rather than [DataTable]: a data table lays its columns
/// out at a fixed width and clips what does not fit, and half the cells in
/// these documents are sentences. The Material treatment is in the styling —
/// the header row, the dividers, the numeric alignment — and not in which
/// widget lays the grid out.
class _TableView extends StatelessWidget {
  final u.USeq value;
  final String path;

  const _TableView({required this.value, required this.path});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = DocumentScope.of(context);
    final columns = tableColumns(value.values)!;
    final rows = [for (final row in value.values) bare(row) as u.UMap];

    // A column of numbers is read down and compared, which wants the digits
    // aligned on the right. A column of anything else is read across.
    final numeric = [
      for (final column in columns)
        rows.every((row) => isNumber(_cell(row, column)!)),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 400),
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          defaultVerticalAlignment: TableCellVerticalAlignment.top,
          border: TableBorder(
            horizontalInside: BorderSide(color: theme.dividerColor),
            bottom: BorderSide(color: theme.dividerColor),
          ),
          children: [
            TableRow(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
              ),
              children: [
                for (var i = 0; i < columns.length; i++)
                  _cellBox(
                    Text(
                      columns[i],
                      textAlign: numeric[i] ? TextAlign.right : TextAlign.start,
                      style: theme.textTheme.labelLarge
                          ?.copyWith(color: scope.palette.name),
                    ),
                  ),
              ],
            ),
            for (var row = 0; row < rows.length; row++)
              TableRow(
                children: [
                  for (var i = 0; i < columns.length; i++)
                    _cellBox(
                      _TableCell(
                        value: _cell(rows[row], columns[i]),
                        alignRight: numeric[i],
                        // Anchors are collected by walking maps, and a table
                        // is a sequence, so nothing can point inside one. A
                        // path built through a row is therefore never a
                        // target, which is what keeps a cell holding a map
                        // from claiming a key some section already has.
                        path: '$path.$row.${columns[i]}',
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _cellBox(Widget child) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: child,
      );

  u.UValue? _cell(u.UMap row, String column) {
    for (final entry in row.entries) {
      if (entry.key == column) return entry.value;
    }
    return null;
  }
}

class _TableCell extends StatelessWidget {
  final u.UValue? value;
  final bool alignRight;
  final String path;

  const _TableCell({
    required this.value,
    required this.alignRight,
    required this.path,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = DocumentScope.of(context).palette;
    final cell = value;

    // A missing cell and an empty one are different claims, and the dot says
    // which this is without saying it loudly.
    if (cell == null) {
      return Text('·', style: TextStyle(color: palette.quiet));
    }

    final content = bare(cell);
    if (content is u.UMap || content is u.USeq) {
      return ValueView(value: cell, path: path);
    }

    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        // Long enough to hold a sentence, short enough that one wordy cell
        // cannot push every other column off the page.
        constraints: const BoxConstraints(maxWidth: 420),
        child: content is u.UReference
            ? scalarText(context, cell, palette)
            : Text(
                scalarLabel(content),
                textAlign: alignRight ? TextAlign.right : TextAlign.start,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scalarColor(content, palette),
                  height: 1.4,
                ),
              ),
      ),
    );
  }
}

String _join(String path, String key) => path.isEmpty ? key : '$path.$key';
