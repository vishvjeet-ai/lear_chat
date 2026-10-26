import 'package:flutter/material.dart';

import '../../core/protocol/constants.dart';
import '../../core/protocol/utf8_limit.dart';

/// Text field with a live UTF-8 byte counter. Send is disabled when the text
/// is empty, over [kMaxTextBytes], or [enabled] is false.
class Composer extends StatefulWidget {
  const Composer({super.key, required this.onSend, required this.enabled, this.disabledHint});

  final Future<void> Function(String text) onSend;
  final bool enabled;

  /// Shown instead of the counter when sending is disabled.
  final String? disabledHint;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _controller = TextEditingController();
  int _bytes = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final bytes = utf8ByteLength(_controller.text);
      if (bytes != _bytes) setState(() => _bytes = bytes);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _over => _bytes > kMaxTextBytes;

  bool get _canSend => widget.enabled && !_over && _controller.text.trim().isNotEmpty;

  Future<void> _send() async {
    if (!_canSend) return;
    final text = _controller.text;
    _controller.clear();
    await widget.onSend(text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.labelSmall;
    final remaining = kMaxTextBytes - _bytes;

    final String hint;
    final Color? hintColor;
    if (!widget.enabled && widget.disabledHint != null) {
      hint = widget.disabledHint!;
      hintColor = scheme.onSurfaceVariant;
    } else if (_over) {
      hint = '$_bytes / $kMaxTextBytes bytes. Shorten by ${-remaining} to send.';
      hintColor = scheme.error;
    } else {
      hint = '$_bytes / $kMaxTextBytes bytes';
      hintColor = remaining < 16 ? scheme.tertiary : scheme.onSurfaceVariant;
    }

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const Key('composer-field'),
                    controller: _controller,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Message',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hint,
                    key: const Key('byte-counter'),
                    style: small?.copyWith(color: hintColor),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: IconButton.filled(
                key: const Key('send-button'),
                tooltip: 'Send',
                onPressed: _canSend ? _send : null,
                icon: const Icon(Icons.send),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
