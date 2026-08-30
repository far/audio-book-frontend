import 'package:flutter/material.dart';

import '../app_state.dart';

/// Shown between "user tapped a chapter" and "the first chunk is ready" --
/// the tech doc's "Generating voice…" progress step, now backed by a real
/// wait (first chunk_ready event or a timeout) rather than a UI-only flash.
class BufferingScreen extends StatelessWidget {
  const BufferingScreen({super.key, required this.state});

  final Buffering state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(state.chapter.title)),
      body: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Generating voice…'),
          ],
        ),
      ),
    );
  }
}
