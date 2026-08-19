import 'package:flutter/material.dart';
import 'package:unimsg/unimsg.dart' as u;

import 'notes.dart';
import 'palette.dart';
import 'shape.dart';
import 'value_view.dart';

/// A file, read as a document or not read at all.
///
/// A `.umsg` file being edited is invalid for most of the time a person
/// spends typing in it, so failing to parse is an ordinary state and not an
/// error condition. The caller gets both answers and decides what to show.
class DocumentSource {
  final u.UnimsgDocument? document;
  final u.UnimsgException? error;

  const DocumentSource._(this.document, this.error, this.text);

  /// The text it was read from, kept because the tree does not carry all of
  /// it — see [leadingComments].
  final String? text;

  factory DocumentSource.read(String source) {
    try {
      return DocumentSource._(u.parse(source), null, source);
    } on u.UnimsgException catch (error) {
      return DocumentSource._(null, error, source);
    }
  }

  bool get isDocument => document != null;

  /// What went wrong, in a line, with the place it went wrong.
  String? get says => error == null
      ? null
      : 'line ${error!.line}, column ${error!.column}: ${error!.message}';
}

/// What every part of the page needs to know about the document it is in.
class DocumentScope extends InheritedWidget {
  final Anchors anchors;
  final UnimsgPalette palette;

  /// A key for the widget at [path], or null when nothing points there.
  final GlobalKey? Function(String path) keyFor;

  /// Scrolls to [path].
  final void Function(String path) goTo;

  const DocumentScope({
    super.key,
    required this.anchors,
    required this.palette,
    required this.keyFor,
    required this.goTo,
    required super.child,
  });

  static DocumentScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DocumentScope>()!;

  @override
  bool updateShouldNotify(DocumentScope old) =>
      old.anchors != anchors || old.palette != palette;
}

/// A unimsg document, as a page.
class UnimsgDocumentView extends StatefulWidget {
  final u.UnimsgDocument document;

  /// What to call the document — usually the file name, since a document does
  /// not necessarily name itself.
  final String title;

  /// Where the colours come from. Null takes Material's own, which is right
  /// for a host with no other view of the same data to agree with.
  final UnimsgPalette? palette;

  /// The text the document was parsed from, if the caller still has it. Only
  /// the preamble needs it, and only until the parser keeps one — see
  /// [leadingComments].
  final String? source;

  const UnimsgDocumentView({
    super.key,
    required this.document,
    required this.title,
    this.palette,
    this.source,
  });

  @override
  State<UnimsgDocumentView> createState() => _UnimsgDocumentViewState();
}

class _UnimsgDocumentViewState extends State<UnimsgDocumentView> {
  late DocumentShape _shape;
  late Anchors _anchors;

  /// One key per place a reference can land, made once and kept.
  ///
  /// Kept rather than rebuilt because a [GlobalKey] identifies a widget across
  /// rebuilds, and handing out a fresh one each frame would move every anchor
  /// out from under the reader between the tap and the scroll.
  final Map<String, GlobalKey> _keys = {};

  /// The scroll view, so the contents can tell which section the reader is
  /// looking at.
  final _scroll = ScrollController();
  final _viewport = GlobalKey();

  /// Which section the contents shows as the one being read.
  int _here = 0;

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void didUpdateWidget(UnimsgDocumentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.document, widget.document)) {
      _keys.clear();
      _here = 0;
      _read();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _read() {
    _shape = DocumentShape.of(widget.document, source: widget.source);
    _anchors = anchorsOf(_shape);
  }

  /// Which section the top of the viewport is inside.
  ///
  /// Measured from where the headings actually are rather than from a table
  /// of offsets, because the offsets change whenever a note is opened and a
  /// contents list that lags what is on screen is worse than none.
  void _trackPosition() {
    final viewport = _viewport.currentContext?.findRenderObject();
    if (viewport is! RenderBox) return;
    // A heading is "reached" a little before it touches the top edge, so that
    // scrolling a section into view marks it rather than the one above.
    final line = viewport.localToGlobal(Offset.zero).dy + 96;

    var here = 0;
    for (var i = 0; i < _shape.sections.length; i++) {
      final target = _keys[_shape.sections[i].key]?.currentContext;
      final box = target?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      if (box.localToGlobal(Offset.zero).dy > line) break;
      here = i;
    }
    if (here != _here) setState(() => _here = here);
  }

  GlobalKey? _keyFor(String path) {
    if (path.isEmpty || !_anchors.isTarget(path)) return null;
    return _keys.putIfAbsent(path, GlobalKey.new);
  }

  void _goTo(String path) {
    final target = _keys[path]?.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      // Not flush with the top: a heading pinned to the very edge reads as
      // having nothing above it, and a reader loses where they arrived from.
      alignment: 0.08,
    );
  }

  /// Below this the pane is too narrow to give a column away, and the
  /// contents becomes something to open instead of something to glance at.
  static const _roomForContents = 840.0;

  @override
  Widget build(BuildContext context) {
    return DocumentScope(
      anchors: _anchors,
      palette: widget.palette ?? UnimsgPalette.of(context),
      keyFor: _keyFor,
      goTo: _goTo,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final beside = constraints.maxWidth >= _roomForContents &&
              _shape.sections.length > 1;

          // The whole page at once rather than a lazy list. A reference has to
          // be able to reach a heading twenty sections down, and a list that
          // has not built that section has nowhere to scroll to. These are
          // documents — the largest here is a few thousand widgets, built once
          // when the file is opened.
          final page = NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification) _trackPosition();
              return false;
            },
            child: SelectionArea(
              child: SingleChildScrollView(
                key: _viewport,
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 48),
                child: Center(
                  child: ConstrainedBox(
                    // A line of prose is read, and a line too long to track
                    // back to the start of is read twice.
                    constraints: const BoxConstraints(maxWidth: 980),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Head(shape: _shape, title: widget.title),
                        if (!beside && _shape.sections.length > 1)
                          _ContentsTile(sections: _shape.sections, here: _here),
                        for (final section in _shape.sections)
                          _Section(entry: section),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );

          if (!beside) return page;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 236,
                child: _ContentsRail(sections: _shape.sections, here: _here),
              ),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(child: page),
            ],
          );
        },
      ),
    );
  }
}

/// The sections, as a list to jump from.
///
/// Names the keys rather than the banners an author drew over them. A banner
/// is more human, but the key is what a reference names and what the heading
/// says, and a contents list whose entries do not match the headings they
/// lead to is a second set of names to learn.
class _ContentsList extends StatelessWidget {
  final List<u.MapEntry> sections;
  final int here;
  final bool dense;

  const _ContentsList({
    required this.sections,
    required this.here,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = DocumentScope.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < sections.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            child: ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
              minVerticalPadding: 0,
              // The shape Material 3 gives a selected destination.
              shape: const StadiumBorder(),
              selected: i == here,
              selectedTileColor: theme.colorScheme.secondaryContainer,
              selectedColor: theme.colorScheme.onSecondaryContainer,
              title: Text(
                sections[i].key,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: dense
                    ? theme.textTheme.bodySmall
                    : theme.textTheme.bodyMedium,
              ),
              onTap: () => scope.goTo(sections[i].key),
            ),
          ),
      ],
    );
  }
}

/// The contents beside the document, staying put while it scrolls.
class _ContentsRail extends StatelessWidget {
  final List<u.MapEntry> sections;
  final int here;

  const _ContentsRail({required this.sections, required this.here});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A Material rather than a coloured box: a ListTile paints its selection
    // and its ink on the nearest Material ancestor, so a plain background in
    // between would hide both — the tile would look selected nowhere and
    // splash nowhere.
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 16, 8),
            child: Text(
              'Contents',
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          // Its own scroll: a document with thirty sections has a contents
          // list longer than the pane, and pinning it would cut the tail off.
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 24),
              child: _ContentsList(sections: sections, here: here),
            ),
          ),
        ],
      ),
    );
  }
}

/// The contents where there is no room beside the document: offered at the
/// top, closed, so it costs one line until it is wanted.
class _ContentsTile extends StatelessWidget {
  final List<u.MapEntry> sections;
  final int here;

  const _ContentsTile({required this.sections, required this.here});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        margin: EdgeInsets.zero,
        child: Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            leading: const Icon(Icons.list_alt_outlined, size: 20),
            title: Text('Contents', style: theme.textTheme.labelLarge),
            subtitle: Text(
              '${sections.length} sections',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            childrenPadding: const EdgeInsets.only(bottom: 10),
            children: [
              _ContentsList(sections: sections, here: here, dense: true),
            ],
          ),
        ),
      ),
    );
  }
}

class _Head extends StatelessWidget {
  final DocumentShape shape;
  final String title;

  const _Head({required this.shape, required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = DocumentScope.of(context).palette;
    final preamble = readNote(shape.preamble);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (shape.envelope != null)
                Text(
                  shape.envelope!,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: palette.name),
                ),
              for (final annotation in shape.envelopeAnnotations)
                Text(
                  annotation is u.IdentifierAnnotation
                      ? '@${annotation.name}'
                      : ':${annotation.name}',
                  style:
                      theme.textTheme.labelMedium?.copyWith(color: palette.meta),
                ),
              Text(
                shape.header ?? 'no header',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: palette.quiet,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          if (!preamble.isEmpty) _Preamble(note: preamble),
        ],
      ),
    );
  }
}

/// What the author wrote at the top of the file, before anything else.
///
/// Open, where a section's note is closed. There is one of these and there
/// are dozens of those: collapsing the many keeps the page skimmable, and
/// collapsing the one hides the paragraph that says what the reader is
/// looking at.
class _Preamble extends StatelessWidget {
  final Note note;
  const _Preamble({required this.note});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = DocumentScope.of(context).palette;

    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.only(left: 14),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: theme.colorScheme.outlineVariant, width: 2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (note.title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                note.title!,
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: palette.quiet),
              ),
            ),
          for (final paragraph in note.paragraphs)
            Padding(
              padding: EdgeInsets.only(
                bottom: paragraph == note.paragraphs.last ? 0 : 10,
              ),
              child: Text.rich(
                TextSpan(
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(height: 1.55, color: palette.quiet),
                  children: [
                    for (final fragment in fragments(paragraph))
                      TextSpan(
                        text: fragment.text,
                        style: fragment.isCode
                            ? TextStyle(
                                fontFamily: 'monospace',
                                color: palette.name,
                              )
                            : null,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One top-level pair, as a section of the page.
///
/// Depth is the document's own: what the author nested is what a reader sees
/// nested, and nothing is promoted or hidden to make the page tidier.
class _Section extends StatelessWidget {
  final u.MapEntry entry;
  const _Section({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = DocumentScope.of(context);
    final note = readNote(entry.comments);
    final annotations = annotationsOf(entry.value);

    return Padding(
      key: scope.keyFor(entry.key),
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(entry.key, style: theme.textTheme.titleLarge),
              ),
              for (final annotation in annotations) ...[
                const SizedBox(width: 8),
                Text(
                  annotation is u.IdentifierAnnotation
                      ? '@${annotation.name}'
                      : ':${annotation.name}',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: scope.palette.meta),
                ),
              ],
            ],
          ),

          // A banner the author drew over this part is their own name for it,
          // and often more human than the key. It is still commentary, so it
          // sits under the heading rather than in place of it.
          if (note.isBannerOnly)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                note.title!.toLowerCase(),
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: scope.palette.quiet),
              ),
            ),

          const Padding(
            padding: EdgeInsets.only(top: 8, bottom: 12),
            child: Divider(height: 1),
          ),

          if (!note.isEmpty && !note.isBannerOnly)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: NoteView(note: note),
            ),

          ValueView(value: entry.value, path: entry.key),
        ],
      ),
    );
  }
}

/// A note the author left beside something, offered rather than imposed.
///
/// Material's own disclosure: it opens on a click or a tap, it is operable
/// from a keyboard, it announces itself as expandable to a screen reader, and
/// it looks like every other expander in the window. A hand-drawn one would
/// have to be given all four, and would still behave like nothing else here.
class NoteView extends StatelessWidget {
  final Note note;
  const NoteView({super.key, required this.note});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = DocumentScope.of(context).palette;
    if (note.isEmpty || note.isBannerOnly) return const SizedBox.shrink();

    return Theme(
      // A note is an aside. Material's default expander draws a divider above
      // and below, which fences it off as a section of its own.
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: 12, bottom: 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        leading: Icon(Icons.subject, size: 18, color: palette.quiet),
        title: Text(
          note.summary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelMedium?.copyWith(color: palette.quiet),
        ),
        children: [
          for (final paragraph in note.paragraphs)
            Padding(
              padding: EdgeInsets.only(
                bottom: paragraph == note.paragraphs.last ? 0 : 10,
              ),
              child: Text.rich(
                TextSpan(
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                  children: [
                    for (final fragment in fragments(paragraph))
                      TextSpan(
                        text: fragment.text,
                        style: fragment.isCode
                            ? TextStyle(
                                fontFamily: 'monospace',
                                color: palette.name,
                              )
                            : null,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
