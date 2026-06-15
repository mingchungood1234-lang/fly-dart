import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    // Wait a brief moment for splash screen visibility
    await Future.delayed(const Duration(milliseconds: 500));

    if (!mounted) return;

    final token = await AuthService.getToken();

    if (token == null || token.isEmpty) {
      // No token found, go to login
      _navigateToLogin();
      return;
    }

    // Token exists, try to refresh it with the server
    try {
      final refreshResult = await ApiService.refreshToken(token);

      if (refreshResult['success'] == true && refreshResult['token'] != null) {
        // Token refreshed successfully, save the new token and user data
        final newToken = refreshResult['token'] as String;
        final user = refreshResult['user'];
        if (user != null) {
          await AuthService.saveAuth(
            token: newToken,
            user: user,
          );
        }
        _navigateToHome();
      } else {
        // Token invalid/expired
        await AuthService.clearAuth();
        _navigateToLogin(message: 'Session expired. Please login again.');
      }
    } catch (e) {
      // Network error or server down - allow offline access with cached data
      final cachedUser = await AuthService.getUser();
      if (cachedUser != null) {
        // User has cached data, try to use it (offline mode)
        _navigateToHome();
      } else {
        // No cached data, go to login
        await AuthService.clearAuth();
        _navigateToLogin(message: 'Unable to connect. Please login again.');
      }
    }
  }

  void _navigateToHome() {
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/home');
  }

  void _navigateToLogin({String? message}) {
    if (!mounted) return;
    Navigator.pushReplacementNamed(
      context,
      '/login',
      arguments: message,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // App logo
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.phone,
                size: 50,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'PhoneCall',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Loading...',
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }
}
