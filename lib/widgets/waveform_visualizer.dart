import 'package:flutter/material.dart';

class WaveformVisualizer extends StatefulWidget {
  final double level; // 0 to 100
  final bool isRecording;
  
  const WaveformVisualizer({
    super.key,
    required this.level,
    this.isRecording = false,
  });

  @override
  State<WaveformVisualizer> createState() => _WaveformVisualizerState();
}

class _WaveformVisualizerState extends State<WaveformVisualizer> {
  // Store history of levels to create scrolling effect
  // Increased to 120 for finer grain (more bars)
  final List<double> _levelHistory = List.filled(120, 0.0, growable: true);

  @override
  void didUpdateWidget(WaveformVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // Reset visualizer when recording starts
    if (!oldWidget.isRecording && widget.isRecording) {
      setState(() {
        _levelHistory.fillRange(0, _levelHistory.length, 0.0);
      });
    }

    if (oldWidget.level != widget.level) {
      // Add new level to history and remove oldest
      setState(() {
        _levelHistory.add(widget.level);
        if (_levelHistory.length > 120) {
          _levelHistory.removeAt(0);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Waveform visualization using CustomPainter for performance and detail
        SizedBox(
          height: 80, // slightly taller for better range
          width: double.infinity,
          child: CustomPaint(
            painter: WaveformPainter(
              samples: _levelHistory,
              color: const Color(0xFF2E7D32), // Dark green
            ),
          ),
        ),
      ],
    );
  }
}

class WaveformPainter extends CustomPainter {
  final List<double> samples;
  final Color color;

  WaveformPainter({
    required this.samples,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round;

    // Calculate dynamic width based on available space and sample count
    // Use a smaller gap for finer bars
    final gap = 1.5;
    // ensure we don't divide by zero
    if (samples.isEmpty) return;
    
    final totalGaps = (samples.length - 1) * gap;
    final availableWidth = size.width - totalGaps;
    final barWidth = availableWidth / samples.length;

    for (int i = 0; i < samples.length; i++) {
      final sample = samples[i];
      // Normalize height (0-100 to 0.0-1.0)
      final normalizedHeight = (sample / 100).clamp(0.0, 1.0);
      
      // Calculate bar height with a minimum of 4.0
      final barHeight = 4.0 + (normalizedHeight * (size.height - 4.0));
      
      // Calculate X position
      final x = i * (barWidth + gap);
      
      // Center Y position
      final y = (size.height - barHeight) / 2;

      // Draw rounded rect
      // Dynamic opacity for "scrolling" fade effect on the left
      double opacity = 0.8;
      if (i < 10) {
        opacity = 0.2 + (i / 10) * 0.6;
      }
      paint.color = color.withOpacity(opacity);

      // Using RRect for proper rounded corners
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barWidth, barHeight),
        const Radius.circular(4),
      );
      
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return true; // Repaint whenever recreated with new samples
  }
}
