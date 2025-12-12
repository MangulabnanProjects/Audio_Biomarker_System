import 'package:flutter/material.dart';

class RecordButton extends StatefulWidget {
  final bool isRecording;
  final VoidCallback onPressed;
  
  const RecordButton({
    super.key,
    required this.isRecording,
    required this.onPressed,
  });

  @override
  State<RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<RecordButton> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(RecordButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRecording != oldWidget.isRecording) {
      if (widget.isRecording) {
        _controller.repeat(reverse: true);
      } else {
        _controller.stop();
        _controller.reset();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onPressed,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Pulse Effect (only when recording)
          if (widget.isRecording)
            AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                return Opacity(
                  opacity: (1.2 - _scaleAnimation.value) * 1.0,
                  child: Container(
                    width: 80 * _scaleAnimation.value,
                    height: 80 * _scaleAnimation.value,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF81C784).withOpacity(0.2), // Light green
                    ),
                  ),
                );
              },
            ),

          // Main Button
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOutBack,
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.isRecording 
                ? const Color(0xFF66BB6A) // Medium green when recording
                : const Color(0xFFA5D6A7), // Light mint green when ready
              border: Border.all(
                color: Colors.black87, // Black border
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF81C784).withOpacity(widget.isRecording ? 0.4 : 0.3),
                  blurRadius: widget.isRecording ? 15 : 10,
                  spreadRadius: widget.isRecording ? 2 : 2,
                ),
              ],
            ),
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                child: Icon(
                  widget.isRecording ? Icons.stop_rounded : Icons.mic_none_rounded,
                  key: ValueKey(widget.isRecording),
                  color: Colors.black87, // Black icon
                  size: 36,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
