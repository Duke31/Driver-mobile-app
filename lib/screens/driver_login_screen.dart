import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/driver_model.dart';
import 'main_driver_screen.dart';

class DriverLoginScreen extends StatefulWidget {
  const DriverLoginScreen({super.key});

  @override
  State<DriverLoginScreen> createState() => _DriverLoginScreenState();
}

class _DriverLoginScreenState extends State<DriverLoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _isCheckingSavedSession = true;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _checkExistingAuthSession();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _checkExistingAuthSession() async {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session != null && !session.isExpired) {
        // Attempt to load driver profile linked to this authenticated session
        final res = await Supabase.instance.client.rpc('get_current_driver');
        if (res != null) {
          final driver = DriverModel.fromJson(Map<String, dynamic>.from(res as Map));
          if (mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => MainDriverScreen(driver: driver),
              ),
            );
            return;
          }
        }
      }
    } catch (e) {
      debugPrint('Session restore error: $e');
    } finally {
      if (mounted) {
        setState(() => _isCheckingSavedSession = false);
      }
    }
  }

  Future<void> _signIn() async {
    String input = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (input.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = 'Please enter both your driver email/identifier and password.');
      return;
    }

    // If driver entered plain username or phone, format as email if needed
    String email = input;
    if (!email.contains('@')) {
      email = '$input@ems-dispatch.org';
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 1. Native Supabase Auth Sign In (Option B)
      final authResponse = await Supabase.instance.client.auth.signInWithPassword(
        email: email,
        password: password,
      );

      if (authResponse.user == null) {
        throw Exception('Sign in failed. No active user returned.');
      }

      // 2. Fetch driver profile linked to this auth user
      final driverRes = await Supabase.instance.client.rpc('get_current_driver');
      
      if (driverRes == null) {
        // Fallback: If no driver row linked yet, construct from auth metadata or prompt admin
        final user = authResponse.user!;
        final fallbackDriver = DriverModel(
          id: user.id,
          userId: user.id,
          displayName: user.userMetadata?['display_name'] ?? user.email?.split('@').first ?? 'Ambulance Unit',
          vehicleLabel: user.userMetadata?['vehicle_label'] ?? 'Ambulance Unit',
          active: true,
        );

        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => MainDriverScreen(driver: fallbackDriver),
            ),
          );
        }
        return;
      }

      final driver = DriverModel.fromJson(Map<String, dynamic>.from(driverRes as Map));

      if (!driver.active) {
        await Supabase.instance.client.auth.signOut();
        throw Exception('Your ambulance unit is currently marked inactive by dispatch.');
      }

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => MainDriverScreen(driver: driver),
          ),
        );
      }
    } catch (e) {
      String cleanMsg = e.toString();
      if (cleanMsg.contains('Exception:')) {
        cleanMsg = cleanMsg.split('Exception:').last.trim();
      }
      if (cleanMsg.contains('Invalid login credentials')) {
        cleanMsg = 'Invalid email or password. Please verify your credentials.';
      }
      setState(() {
        _errorMessage = cleanMsg;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isCheckingSavedSession) {
      return const Scaffold(
        backgroundColor: Color(0xFF061536),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.redAccent),
              SizedBox(height: 16),
              Text(
                'Checking Driver Session...',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF061536),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              // Solace App Logo & Header
              Center(
                child: Column(
                  children: [
                    Image.asset(
                      'assets/images/solace_logo.png',
                      height: 104,
                      width: 104,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Container(
                        height: 80,
                        width: 80,
                        decoration: BoxDecoration(
                          color: const Color(0xFF061536),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFF00D4FF), width: 1.5),
                        ),
                        child: const Icon(Icons.emergency_rounded, color: Color(0xFF00D4FF), size: 40),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Solace',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'EMERGENCY DISPATCH • DRIVER CONSOLE',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2.2,
                        color: Color(0xFF00D4FF),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Info Banner
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A1E4A),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.06)),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Individual Driver Sign In',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Sign in with your individual EMS account credentials to access your live mission console, view available dispatches, and track hospital intake.',
                      style: TextStyle(
                        fontSize: 13,
                        color: Color(0xFF94A3B8),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Email / Username field
              const Text(
                'DRIVER EMAIL OR IDENTIFIER',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: Color(0xFF94A3B8),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'e.g. driver@ems-fleet.org',
                  hintStyle: const TextStyle(color: Colors.white38),
                  prefixIcon: const Icon(Icons.badge_rounded, color: Colors.white60),
                  filled: true,
                  fillColor: const Color(0xFF0A1E4A),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Colors.redAccent, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // Password field
              const Text(
                'PASSWORD',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: Color(0xFF94A3B8),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Enter your password',
                  hintStyle: const TextStyle(color: Colors.white38),
                  prefixIcon: const Icon(Icons.lock_outline_rounded, color: Colors.white60),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility_off : Icons.visibility,
                      color: Colors.white60,
                    ),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF0A1E4A),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Colors.redAccent, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Error display
              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade900.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Sign In Button
              ElevatedButton(
                onPressed: _isLoading ? null : _signIn,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.redAccent.withOpacity(0.5),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  elevation: 2,
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.login_rounded, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'SIGN IN AS AMBULANCE DRIVER',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 30),

              // Footer Note
              const Center(
                child: Text(
                  'Authenticated via Supabase Auth • Zero-Trust EMS Security\nAuthorized Emergency Personnel Only',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white38,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
