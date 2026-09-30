import 'package:flutter/material.dart';
import 'package:pi_droid/toolchain_canary.dart';

void main() {
  runApp(const MainApp());
}

/// App root. Renders the toolchain canary so the platform proof in step 8
/// exercises hand-written code rather than template output.
///
/// This is scaffolding, not product UI — the real shell replaces it, arriving
/// with its own failing test.
class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(child: Text(canaryAnswer().toString())),
      ),
    );
  }
}
