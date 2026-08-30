import 'package:flutter/material.dart';

import '../app_state.dart';

const _speedSteps = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

/// Height of the play/pause slot. Also the row's height, so the controls
/// -- and the text above them -- stay put whatever the slot contains.
const _playSlot = 56.0;

/// Play/pause, previous/next part, and speed.
///
/// Previous/next step by *chunk*, not chapter -- a chunk is the unit the
/// player's playlist is built from and the unit the text highlights, so
/// skipping by anything else would put the controls and the page out of
/// step. They use the familiar track-skip icons for that reason: within a
/// chapter, a chunk is what a track is on a music player.
class PlaybackControls extends StatelessWidget {
  const PlaybackControls({
    super.key,
    required this.state,
    required this.onTogglePlayPause,
    required this.onSpeedChanged,
    required this.onPrevious,
    required this.onNext,
  });

  final Reading state;
  final VoidCallback onTogglePlayPause;
  final ValueChanged<double> onSpeedChanged;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final isFirst = state.currentChunkIndex <= 0;
    final isLast = state.currentChunkIndex >= state.chapter.chunks.length - 1;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            iconSize: 36,
            icon: const Icon(Icons.skip_previous),
            tooltip: 'Previous part',
            // Disabled rather than hidden at the ends, so the controls
            // don't shift position mid-chapter.
            onPressed: isFirst ? null : onPrevious,
          ),
          // Fixed slot: the spinner and the button have different intrinsic
          // sizes (an IconButton adds 8px of padding around its icon), so
          // swapping them resized the row -- and with it the text above,
          // which jumped every time a part started loading.
          SizedBox(
            width: _playSlot,
            height: _playSlot,
            child: state.bufferingState == BufferingState.buffering
                ? const Center(
                    child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    iconSize: 48,
                    padding: EdgeInsets.zero,
                    icon: Icon(state.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled),
                    tooltip: state.isPlaying ? 'Pause' : 'Play',
                    onPressed: onTogglePlayPause,
                  ),
          ),
          IconButton(
            iconSize: 36,
            icon: const Icon(Icons.skip_next),
            tooltip: 'Next part',
            onPressed: isLast ? null : onNext,
          ),
          DropdownButton<double>(
            value: state.speed,
            items: _speedSteps.map((s) => DropdownMenuItem(value: s, child: Text('${s}x'))).toList(),
            onChanged: (value) {
              if (value != null) onSpeedChanged(value);
            },
          ),
        ],
      ),
    );
  }
}
