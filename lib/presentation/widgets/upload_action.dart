import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// Picks an EPUB and starts reading it, replacing whatever is open.
///
/// Shared by the upload screen and the app-bar button so the two can't
/// drift: the picker options matter (`withData: true` is what makes the
/// bytes available for client-side image extraction on every platform,
/// including web, where there is no file path to read back).
Future<void> pickAndUploadEpub(WidgetRef ref) async {
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['epub'],
    withData: true,
  );
  final file = result?.files.single;
  if (file?.bytes == null) return;

  await ref.read(readerNotifierProvider.notifier).uploadAndStart(bytes: file!.bytes!, filename: file.name);
}

/// App-bar action for opening a different book without backing out to the
/// upload screen first.
class UploadFileButton extends ConsumerWidget {
  const UploadFileButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      icon: const Icon(Icons.file_open_outlined),
      tooltip: 'Open another book',
      onPressed: () => pickAndUploadEpub(ref),
    );
  }
}
