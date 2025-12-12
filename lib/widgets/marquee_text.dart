import 'package:flutter/material.dart';

class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final Duration duration;

  const MarqueeText({
    super.key,
    required this.text,
    this.style,
    this.duration = const Duration(seconds: 3),
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late ScrollController _scrollController;
  bool _isScrolling = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startScrolling();
    });
  }

  void _startScrolling() async {
    if (!mounted) return;
    
    // Check if text is overflowing
    final textPainter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();

    if (textPainter.width > _scrollController.position.viewportDimension) {
      setState(() => _isScrolling = true);
      
      while (mounted && _isScrolling) {
        await Future.delayed(const Duration(seconds: 1));
        if (!mounted || !_isScrolling) break;
        
        // Scroll to end
        await _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: widget.duration,
          curve: Curves.linear,
        );
        
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted || !_isScrolling) break;
        
        // Scroll back to start
        await _scrollController.animateTo(
          0,
          duration: widget.duration,
          curve: Curves.linear,
        );
        
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  @override
  void dispose() {
    _isScrolling = false;
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      controller: _scrollController,
      child: Text(
        widget.text,
        style: widget.style,
        maxLines: 1,
        overflow: TextOverflow.visible,
      ),
    );
  }
}
