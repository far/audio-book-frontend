import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/upload_action.dart';
import 'settings_screen.dart';

class UploadScreen extends ConsumerWidget {
  const UploadScreen({super.key, this.errorMessage, required this.statusText});

  final String? errorMessage;
  final String statusText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Reader'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(statusText, style: Theme.of(context).textTheme.bodyLarge),
              if (errorMessage != null) ...[
                const SizedBox(height: 8),
                Text(errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () => pickAndUploadEpub(ref),
                icon: const Icon(Icons.upload_file),
                label: const Text('Upload EPUB'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
