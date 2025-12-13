import 'package:flutter/material.dart';

/// A static waveform visualizer that displays pre-recorded amplitude data
/// Used for showing saved waveforms in the audio player
class StaticWaveformVisualizer extends StatelessWidget {
  final List<double> samples; // Pre-recorded amplitude data (0 to 100 scale)
  final Color color;
  final double height;
  final double? playbackProgress; // 0.0 to 1.0, optional playback indicator

  const StaticWaveformVisualizer({
    super.key,
    required this.samples,
    this.color = const Color(0xFF2E7D32),
    this.height = 60,
    this.playbackProgress,
  });

  @override
  Widget build(BuildContext context) {
    if (samples.isEmpty) {
      return SizedBox(
        height: height,
        child: const Center(
          child: Text(
            'No waveform data',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ),
      );
    }

    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: StaticWaveformPainter(
          samples: samples,
          color: color,
          playbackProgress: playbackProgress,
        ),
      ),
    );
  }
}

class StaticWaveformPainter extends CustomPainter {
  final List<double> samples;
  final Color color;
  final double? playbackProgress;

  StaticWaveformPainter({
    required this.samples,
    required this.color,
    this.playbackProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;

    final paint = Paint()
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round;

    // Calculate bar dimensions
    final gap = 1.5;
    final totalGaps = (samples.length - 1) * gap;
    final availableWidth = size.width - totalGaps;
    final barWidth = availableWidth / samples.length;

    // Calculate which bar the playback is at
    int playbackBar = -1;
    if (playbackProgress != null) {
      playbackBar = (playbackProgress! * samples.length).floor();
    }

    for (int i = 0; i < samples.length; i++) {
      final sample = samples[i];
      // Normalize height (0-100 to 0.0-1.0)
      final normalizedHeight = (sample / 100).clamp(0.0, 1.0);
      
      // Calculate bar height with a minimum of 3.0
      final barHeight = 3.0 + (normalizedHeight * (size.height - 3.0));
      
      // Calculate X position
      final x = i * (barWidth + gap);
      
      // Center Y position
      final y = (size.height - barHeight) / 2;

      // Determine color based on playback position
      if (playbackProgress != null && i <= playbackBar) {
        // Played portion - full color
        paint.color = color;
      } else {
        // Unplayed portion - faded
        paint.color = color.withOpacity(0.3);
      }

      // Draw rounded rect
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barWidth, barHeight),
        const Radius.circular(3),
      );
      
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant StaticWaveformPainter oldDelegate) {
    return oldDelegate.samples != samples || 
           oldDelegate.playbackProgress != playbackProgress;
  }
}
