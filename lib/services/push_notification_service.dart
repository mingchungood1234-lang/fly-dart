import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'api_service.dart';
import 'auth_service.dart';

/// Singleton service for managing push notifications via OneSignal.
/// Handles initialization, device token registration, and notification actions.
class PushNotificationService {
  static final PushNotificationService _instance =
      PushNotificationService._internal();
  factory PushNotificationService() => _instance;
  PushNotificationService._internal();

  // OneSignal App ID — read from .env file (ONESIGNAL_APP_ID)
  String get _oneSignalAppId => dotenv.env['ONESIGNAL_APP_ID'] ?? '';

  String? _deviceId;
  bool _initialized = false;

  /// The OneSignal push subscription ID (device token) for this device
  String? get deviceId => _deviceId;

  /// Whether OneSignal has been initialized
  bool get isInitialized => _initialized;

  /// Initialize OneSignal and register for push notifications.
  /// Call this once at app startup (in main.dart or after login).
  Future<void> initialize() async {
    if (_initialized) return;
    if (_oneSignalAppId.isEmpty) {
      debugPrint('PushNotificationService: No OneSignal App ID configured');
      return;
    }

    try {
      // Set logging level for debugging (remove in production)
      OneSignal.Debug.setLogLevel(OSLogLevel.verbose);

      // Initialize OneSignal with your App ID
      OneSignal.initialize(_oneSignalAppId);

      // Request notification permission (shows native permission dialog)
      final permission = await OneSignal.Notifications.requestPermission(true);
      debugPrint('Push notification permission: $permission');

      // Get the device ID (push subscription ID)
      final subscription = OneSignal.User.pushSubscription;
      _deviceId = subscription.id;
      debugPrint('OneSignal device ID: $_deviceId');

      // Listen for subscription changes (token refresh)
      subscription.addObserver((state) {
        final newId = state.current.id;
        if (newId != _deviceId) {
          debugPrint('Push token refreshed: $newId');
          _deviceId = newId;
          _registerTokenWithServer();
        }
      });

      // Listen for notification received (foreground)
      OneSignal.Notifications.addForegroundWillDisplayListener((event) {
        debugPrint('Notification received in foreground: ${event.notification.title}');
        // Show the notification even when app is in foreground
        event.notification.display();
      });

      // Listen for notification opened (user tapped notification)
      OneSignal.Notifications.addClickListener((event) {
        debugPrint('Notification opened: ${event.notification.title}');
        _handleNotificationTap(event.notification);
      });

      _initialized = true;
      debugPrint('PushNotificationService initialized');
    } catch (e) {
      debugPrint('PushNotificationService init error: $e');
    }
  }

  /// Register the current device token with the server.
  /// Call this after login and after token refresh.
  Future<void> _registerTokenWithServer() async {
    if (_deviceId == null) return;

    try {
      final token = await AuthService.getToken();
      if (token == null) return;

      final user = await AuthService.getUser();
      if (user == null) return;

      await ApiService.registerDeviceToken(
        authToken: token,
        userId: user.id,
        deviceToken: _deviceId!,
        platform: defaultTargetPlatform.name,
      );
      debugPrint('Device token registered with server');
    } catch (e) {
      debugPrint('Failed to register device token: $e');
    }
  }

  /// Register device token with server. Called after login.
  Future<void> registerAfterLogin() async {
    await initialize();
    await _registerTokenWithServer();
  }

  /// Whether anyone is currently listening to the incoming call stream
  bool _hasStreamListeners = false;

  /// Handle notification tap — extract call data and buffer or stream it
  void _handleNotificationTap(OSNotification notification) {
    final data = notification.additionalData;
    if (data == null) return;

    final type = data['type'] as String?;
    if (type == 'incoming_call') {
      final callData = {
        'callerId': data['callerId'] as String?,
        'callerName': data['callerName'] as String? ?? 'Unknown',
        'callType': data['callType'] as String? ?? 'audio',
      };

      // Always buffer for pending consumption (handles killed-app → tap scenario)
      _pendingNotificationCall = callData;

      // If stream has a live listener, also emit to stream
      if (_hasStreamListeners) {
        _incomingCallController.add(callData);
      }
    }
  }

  // Stream for incoming call events from notification taps
  final StreamController<Map<String, dynamic>> _incomingCallController =
      StreamController<Map<String, dynamic>>.broadcast();

  // Buffer for notification taps that arrive before HomeScreen subscribes
  Map<String, dynamic>? _pendingNotificationCall;

  /// Stream of incoming call events triggered by notification taps
  Stream<Map<String, dynamic>> get onIncomingCall {
    _hasStreamListeners = true;
    // Wrap to track listener state
    return _incomingCallController.stream.map((event) {
      _pendingNotificationCall = null; // Consumed via stream
      return event;
    });
  }

  /// Check if there's a pending notification call (for when app opens from killed state)
  Map<String, dynamic>? consumePendingNotificationCall() {
    final pending = _pendingNotificationCall;
    _pendingNotificationCall = null;
    return pending;
  }

  /// Remove device token from server (call on logout)
  Future<void> unregisterToken() async {
    if (_deviceId == null) return;

    try {
      final token = await AuthService.getToken();
      if (token == null) return;

      await ApiService.removeDeviceToken(
        authToken: token,
        deviceToken: _deviceId!,
      );
      debugPrint('Device token removed from server');
    } catch (e) {
      debugPrint('Failed to remove device token: $e');
    }
  }

  /// Clean up
  void dispose() {
    _hasStreamListeners = false;
    _incomingCallController.close();
  }
}
