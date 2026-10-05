import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_fonts/google_fonts.dart';
import 'config/supabase_config.dart';
import 'screens/driver_login_screen.dart';
import 'services/fcm_notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Force portrait orientation for vehicle dashboard mounts
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Set system UI overlay (transparent status bar)
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  // Initialize Supabase Backend connection
  await Supabase.initialize(
    url: SupabaseConfig.url,
    anonKey: SupabaseConfig.anonKey,
  );

  // Initialize High-Priority FCM Push & Keep-Alive Notification Services
  try {
    await FcmNotificationService().initialize();
  } catch (e) {
    debugPrint('FCM initial startup note: $e');
  }

  runApp(const AmbulanceDriverApp());
}

class AmbulanceDriverApp extends StatelessWidget {
  const AmbulanceDriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Solace Driver Console',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF07193F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF334B),
          secondary: Color(0xFF00D4FF),
          surface: Color(0xFF0A1E4A),
        ),
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
        useMaterial3: true,
      ),
      home: const DriverLoginScreen(),
    );
  }
}
