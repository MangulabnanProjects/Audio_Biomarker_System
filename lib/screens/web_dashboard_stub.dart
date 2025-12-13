import 'package:flutter/material.dart';

// Stub for Mobile builds to avoid dart:html imports
class WebDashboardScreen extends StatelessWidget {
  const WebDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text('Web Dashboard is only available on Web'),
      ),
    );
  }
}
