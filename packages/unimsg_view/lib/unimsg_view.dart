/// Renders a unimsg document as a Material page.
///
/// Nothing here knows what any document means. Every treatment is chosen from
/// structure, type or arithmetic — a map whose values are all maps is a keyed
/// collection whatever it holds, and a sequence of maps with the same keys is
/// a table whether it was written as rows or longhand. A treatment chosen
/// from what a key is *called* would work on the document in front of you and
/// fail silently on the next one.
///
/// ```dart
/// final source = DocumentSource.read(text);
/// if (source.isDocument) {
///   return UnimsgDocumentView(document: source.document!, title: 'spec.umsg');
/// }
/// ```
library;

export 'src/document_view.dart'
    show DocumentSource, DocumentScope, NoteView, UnimsgDocumentView;
export 'src/notes.dart' show Fragment, Note, fragments, readNote;
export 'src/palette.dart' show UnimsgPalette;
export 'src/shape.dart'
    show
        Anchors,
        DocumentShape,
        Treatment,
        anchorsOf,
        annotationsOf,
        asNumber,
        bare,
        isInline,
        isNumber,
        leadingComments,
        longText,
        tableColumns,
        treatmentOf;
export 'src/value_view.dart' show ProseView, ValueView, scalarLabel;
