import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities.dart';
import '../../src/config.dart';
import '../providers.dart';

/// Client-adjustable settings. In-memory only; they reset on restart.
///
/// Stateful for the sake of the address field's controller: a
/// TextEditingController owns a disposable listener and the field's
/// selection, so building one per frame both leaks and resets the caret to
/// the start on every keystroke.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _baseUrlController;

  @override
  void initState() {
    super.initState();
    _baseUrlController = TextEditingController(text: ref.read(apiBaseUrlProvider));
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    super.dispose();
  }

  void _commitBaseUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == ref.read(apiBaseUrlProvider)) return;
    ref.read(apiBaseUrlProvider.notifier).state = trimmed;
  }

  /// Commits the address field and confirms it, so "did that take?" has a
  /// visible answer.
  void _apply() {
    _commitBaseUrl(_baseUrlController.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('Settings applied')));
  }

  void _resetToDefaults() {
    ref.read(apiBaseUrlProvider.notifier).state = apiBaseUrl;
    _baseUrlController.text = apiBaseUrl;
    ref.read(autoPlayProvider.notifier).state = true;
    ref.read(ttsSelectionProvider.notifier).state = TtsSelection.piperDefault;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(onPressed: _resetToDefaults, child: const Text('Reset')),
          TextButton(onPressed: _apply, child: const Text('Apply')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeading('Voice'),
          const SizedBox(height: 4),
          const _VoicePicker(),
          const SizedBox(height: 28),
          const _SectionHeading('Playback'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Auto play', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text(
              'Start reading as soon as a chapter is picked. Off waits for Play — '
              'tapping a paragraph still starts there.',
            ),
            value: ref.watch(autoPlayProvider),
            onChanged: (value) => ref.read(autoPlayProvider.notifier).state = value,
          ),
          const SizedBox(height: 28),
          const _SectionHeading('Backend'),
          const SizedBox(height: 12),
          TextField(
            controller: _baseUrlController,
            decoration: const InputDecoration(
              labelText: 'Backend address',
              hintText: 'http://127.0.0.1:8000',
              border: OutlineInputBorder(),
            ),
            // Committed on submit *and* on focus loss -- the address is
            // typically edited then navigated away from, and silently
            // discarding it there reads as the setting not working.
            // Committed on submit and on focus loss as well as via Apply --
            // an edit that is silently discarded reads as the setting being
            // broken.
            onSubmitted: _commitBaseUrl,
            onTapOutside: (_) => _commitBaseUrl(_baseUrlController.text),
          ),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.primary,
      ),
    );
  }
}




/// Provider and voice, built from what the backend reports.
///
/// The list comes from the server rather than being hardcoded, so a
/// provider whose API key is missing is never offered -- it isn't
/// registered, so it isn't in the response. Nothing here can select
/// something that would then fail.
class _VoicePicker extends ConsumerWidget {
  const _VoicePicker();

  Future<void> _select(WidgetRef ref, TtsSelection selection) async {
    if (ref.read(ttsSelectionProvider) == selection) return;
    ref.read(ttsSelectionProvider.notifier).state = selection;
    // The open chapter's URLs carry the old voice, so it has to be
    // rebuilt or the change appears to do nothing until the next chapter.
    await ref.read(readerNotifierProvider.notifier).reloadForSelectionChange();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final selection = ref.watch(ttsSelectionProvider);

    return ref
        .watch(ttsProvidersProvider)
        .when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          ),
          error: (_, _) => Text(
            'Could not reach the backend to list voices. Check the address below.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
          ),
          data: (providers) {
            if (providers.isEmpty) {
              return Text('The backend has no voices configured.', style: theme.textTheme.bodyMedium);
            }
            final current =
                providers.where((p) => p.name == selection.provider).firstOrNull ?? providers.first;
            final voice =
                current.voices.where((v) => v.id == selection.voiceId).firstOrNull ??
                (current.voices.isNotEmpty ? current.voices.first : null);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _LabelledDropdown<String>(
                  label: 'Provider',
                  value: current.name,
                  items: {for (final p in providers) p.name: p.name},
                  onChanged: (name) {
                    final picked = providers.firstWhere((p) => p.name == name);
                    if (picked.voices.isEmpty) return;
                    _select(ref, TtsSelection(provider: picked.name, voiceId: picked.voices.first.id));
                  },
                ),
                const SizedBox(height: 12),
                _LabelledDropdown<String>(
                  label: 'Voice',
                  value: voice?.id,
                  items: {for (final v in current.voices) v.id: v.name},
                  onChanged: (id) => _select(ref, TtsSelection(provider: current.name, voiceId: id!)),
                ),
                const SizedBox(height: 8),
                Text(
                  'Applies straight away — the open chapter restarts from where you are.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            );
          },
        );
  }
}

class _LabelledDropdown<T> extends StatelessWidget {
  const _LabelledDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final T? value;
  final Map<T, String> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true, // long voice names would otherwise overflow
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      items: [
        for (final entry in items.entries)
          DropdownMenuItem(value: entry.key, child: Text(entry.value, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: items.isEmpty ? null : onChanged,
    );
  }
}
