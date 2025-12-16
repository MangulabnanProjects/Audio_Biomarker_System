import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';
import 'screens/audio_recorder_screen.dart';
import 'screens/admin_login_screen.dart';
// Conditional imports to avoid dart:html errors on mobile
import 'screens/web_dashboard_stub.dart'
    if (dart.library.html) 'screens/web_dashboard_screen.dart';
import 'screens/web_admin_login_stub.dart'
    if (dart.library.html) 'screens/web_admin_login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  
  // Enable persistent login across sessions
  try {
    await FirebaseAuth.instance.setPersistence(Persistence.LOCAL);
  } catch (e) {
    print("Error setting persistence: $e");
  }
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audio Biomarker System',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32)),
        useMaterial3: true,
      ),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator(color: Color(0xFF2E7D32))),
            );
          }
          
          if (snapshot.hasData) {
            // Logged In
            return kIsWeb ? const WebDashboardScreen() : const AudioRecorderScreen();
          }
          
          // Not Logged In
          return kIsWeb ? const WebAdminLoginScreen() : const AdminLoginScreen();
        },
      ),
    );
  }
}
