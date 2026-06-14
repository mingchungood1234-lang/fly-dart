import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

/// Manages the Android foreground service that keeps the app process alive.
///
/// On Android, this starts a foreground service with a persistent notification.
/// The foreground service keeps the app process alive, which in turn keeps the
/// main isolate's Socket.IO signaling connection alive — no duplicate sockets needed.
///
/// On iOS, background services work differently; we rely on CallKit + push notifications instead.
class BackgroundServiceManager {
  static final BackgroundServiceManager _instance = BackgroundServiceManager._();
  factory BackgroundServiceManager() => _instance;
  BackgroundServiceManager._();

  final FlutterBackgroundService _service = FlutterBackgroundService();
  bool _isRunning = false;

  /// Whether the background service is currently running
  bool get isRunning => _isRunning;

  /// Initialize and start the background service.
  /// Call this after login to keep the connection alive.
  Future<void> startService(String userId) async {
    if (_isRunning) return;

    try {
      await _service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: _onStart,
          autoStart: false,
          isForegroundMode: true,
          notificationChannelId: 'phonecall_background',
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: _onStart,
          onBackground: _onIosBackground,
        ),
      );

      await _service.startService();
      _isRunning = true;
      debugPrint('Background service started for user: $userId');
    } catch (e) {
      debugPrint('Failed to start background service: $e');
    }
  }

  /// Stop the background service. Call this on logout.
  Future<void> stopService() async {
    if (!_isRunning) return;

    try {
      _service.invoke('stopService');
      _isRunning = false;
      debugPrint('Background service stopped');
    } catch (e) {
      debugPrint('Failed to stop background service: $e');
    }
  }
}

/// Entry point for the background service isolate.
/// This just keeps the app process alive via a foreground notification.
/// The main isolate's Socket.IO connection stays alive because the process stays alive.
@pragma('vm:entry-point')
void _onStart(ServiceInstance service) async {
  // Listen for stop command from main isolate
  service.on('stopService').listen((_) {
    service.stopSelf();
  });
}

/// iOS background handler — iOS manages background execution differently.
Future<bool> _onIosBackground(ServiceInstance service) async {
  return true;
}
