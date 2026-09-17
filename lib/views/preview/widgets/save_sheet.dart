import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';

/// What the user chose on the save sheet.
class SaveChoice {
  const SaveChoice({
    required this.name,
    required this.toGallery,
    required this.toPdf,
  });

  final String name;

  /// Also write every page into the device gallery.
  final bool toGallery;

  /// Also build a PDF and hand it to the share sheet, so it can go to Files,
  /// Drive, email or anywhere else the device offers.
  final bool toPdf;
}

/// Asks for a name and where the document should end up.
///
/// The library copy is not optional and is not presented as a choice: the app
/// has to keep its own copy for the document to exist at all, and offering a
/// checkbox that cannot be unticked is just noise. Gallery and PDF are the
/// genuine choices, and both are additions rather than alternatives.
/// [appendingTo] is the name of the document these pages are being added to,
/// when the session started from "Add pages" on an existing document. In that
/// case the name is fixed and the sheet says so, rather than asking for one it
/// would then throw away.
Future<SaveChoice?> showSaveSheet(
  BuildContext context, {
  required String suggestedName,
  required int pageCount,
  String? appendingTo,
}) {
  return showModalBottomSheet<SaveChoice>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _SaveSheet(
      suggestedName: suggestedName,
      pageCount: pageCount,
      appendingTo: appendingTo,
    ),
  );
}

class _SaveSheet extends StatefulWidget {
  const _SaveSheet({
    required this.suggestedName,
    required this.pageCount,
    this.appendingTo,
  });

  final String suggestedName;
  final int pageCount;
  final String? appendingTo;

  @override
  State<_SaveSheet> createState() => _SaveSheetState();
}

class _SaveSheetState extends State<_SaveSheet> {
  late final TextEditingController _name =
      TextEditingController(text: widget.suggestedName);
  bool _toGallery = false;
  bool _toPdf = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _isAppending => widget.appendingTo != null;

  void _submit() {
    final trimmed = _isAppending ? widget.appendingTo! : _name.text.trim();
    if (trimmed.isEmpty) return;
    Navigator.of(context).pop(
      SaveChoice(name: trimmed, toGallery: _toGallery, toPdf: _toPdf),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tones = context.tones;
    final pages = '${widget.pageCount} page${widget.pageCount == 1 ? '' : 's'}';

    return Padding(
      // Lift the sheet clear of the keyboard while the name is being edited.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: tones.line,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  _isAppending ? 'Add pages' : 'Save document',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.3),
                ),
                const SizedBox(height: 4),
                Text(
                  _isAppending ? '$pages into "${widget.appendingTo}"' : '$pages ready',
                  style: TextStyle(fontSize: 13, color: tones.fg3),
                ),
                const SizedBox(height: 18),
                if (!_isAppending) ...[
                  TextField(
                    controller: _name,
                    autofocus: false,
                    textInputAction: TextInputAction.done,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _submit(),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 18),
                ],
                Text(
                  'ALSO SAVE A COPY',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                    color: tones.fg3,
                  ),
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _toGallery,
                  onChanged: (value) => setState(() => _toGallery = value),
                  title: const Text('Photo gallery'),
                  subtitle: Text(
                    'One image per page, in a ScanFlow album',
                    style: TextStyle(fontSize: 12, color: tones.fg3),
                  ),
                  secondary: const Icon(Icons.photo_library_outlined),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _toPdf,
                  onChanged: (value) => setState(() => _toPdf = value),
                  title: const Text('PDF'),
                  subtitle: Text(
                    'Opens the share sheet so you can pick where it goes',
                    style: TextStyle(fontSize: 12, color: tones.fg3),
                  ),
                  secondary: const Icon(Icons.picture_as_pdf_outlined),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(Icons.inventory_2_outlined, size: 16, color: tones.fg3),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _isAppending
                            ? 'Added to the document in your ScanFlow library.'
                            : 'Always kept in your ScanFlow library, on this device.',
                        style: TextStyle(fontSize: 12, height: 1.4, color: tones.fg3),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    onPressed: !_isAppending && _name.text.trim().isEmpty ? null : _submit,
                    child: Text(_isAppending ? 'Add pages' : 'Save'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
