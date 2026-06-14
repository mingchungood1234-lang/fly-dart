import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';

/// Service that wraps flutter_callkit_incoming to show native call UI.
/// On iOS, this uses CallKit for the system-level call screen.
/// On Android, this uses a custom full-screen notification overlay.
///
/// When the app is in the background or killed, this provides the native
/// UI for incoming calls instead of a Flutter overlay (which won't work
/// when the app isn't in the foreground).
class CallKitService {
  static final CallKitService _instance = CallKitService._();
  factory CallKitService() => _instance;
  CallKitService._();

  StreamSubscription<CallEvent?>? _eventSubscription;
  String? _currentCallId;
  int _callCounter = 0;

  /// Cache of extra data keyed by call ID, so we can retrieve caller info
  /// when the accept event fires (since CallEventActionCallAccept only has `id`)
  final Map<String, Map<String, dynamic>> _callDataCache = {};

  /// Callback when the user accepts the call via CallKit UI
  /// Receives the full call data (callerId, callerName, callType, etc.)
  Function(Map<String, dynamic> callData)? onCallAccepted;

  /// Callback when the user declines the call via CallKit UI
  Function()? onCallDeclined;

  /// Initialize CallKit event listener. Call this at app startup.
  void initialize() {
    _eventSubscription?.cancel();
    _eventSubscription = FlutterCallkitIncoming.onEvent.listen(_handleCallEvent);
    debugPrint('CallKitService initialized');
  }

  /// Show incoming call UI using the platform-native CallKit/notification.
  /// Returns a unique call ID for tracking.
  String showIncomingCall({
    required String callerId,
    required String callerName,
    required bool isVideo,
    Map<String, dynamic>? extra,
  }) {
    // Generate a unique incrementing ID
    _callCounter++;
    final callId = 'call_${DateTime.now().millisecondsSinceEpoch}_$_callCounter';
    _currentCallId = callId;

    // Build the full call data to cache for later retrieval on accept
    final callData = <String, dynamic>{
      'callerId': callerId,
      'callerName': callerName,
      'callType': isVideo ? 'video' : 'audio',
      ...?extra,
    };
    _callDataCache[callId] = callData;

    final params = CallKitParams(
      id: callId,
      nameCaller: callerName,
      appName: 'PhoneCall',
      handle: callerId,
      type: isVideo ? 1 : 0, // 0 = audio, 1 = video
      extra: callData,
      android: AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        textAccept: 'Accept',
        textDecline: 'Decline',
        backgroundColor: '#091D35',
        actionColor: '#4CAF50',
        incomingCallNotificationChannelName: 'Incoming Calls',
        missedCallNotificationChannelName: 'Missed Calls',
      ),
      ios: IOSParams(
        iconName: 'CallKitIcon',
        handleType: '',
        supportsVideo: true,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
        audioSessionMode: 'default',
        audioSessionActive: true,
        supportsDTMF: true,
      ),
    );

    debugPrint('CallKit: Showing incoming call from $callerName ($callId)');
    FlutterCallkitIncoming.showCallkitIncoming(params);
    return callId;
  }

  /// End an active CallKit call UI
  Future<void> endCall(String callId) async {
    await FlutterCallkitIncoming.endCall(callId);
    if (_currentCallId == callId) {
      _currentCallId = null;
    }
  }

  /// Check if there's an active CallKit call
  Future<bool> hasActiveCall() async {
    final calls = await FlutterCallkitIncoming.activeCalls();
    return calls.isNotEmpty;
  }

  /// Handle CallKit events using the sealed class hierarchy.
  /// CallEvent is a sealed class with subclasses like CallEventActionCallAccept, etc.
  void _handleCallEvent(CallEvent? event) {
    if (event == null) return;

    debugPrint('CallKit event: ${event.eventName}');

    if (event is CallEventActionCallAccept) {
      debugPrint('CallKit: Call accepted (id: ${event.id})');
      final callData = _callDataCache.remove(event.id) ?? {};
      _currentCallId = null;
      onCallAccepted?.call(callData);
    } else if (event is CallEventActionCallDecline) {
      debugPrint('CallKit: Call declined (id: ${event.id})');
      _callDataCache.remove(event.id);
      _currentCallId = null;
      onCallDeclined?.call();
    } else if (event is CallEventActionCallEnded) {
      debugPrint('CallKit: Call ended (id: ${event.id})');
      _callDataCache.remove(event.id);
      _currentCallId = null;
    } else if (event is CallEventActionCallTimeout) {
      debugPrint('CallKit: Call timed out (id: ${event.id})');
      _callDataCache.remove(event.id);
      _currentCallId = null;
    } else if (event is CallEventActionCallIncoming) {
      debugPrint('CallKit: Call incoming received');
    } else {
      debugPrint('CallKit: Other event ${event.eventName}');
    }
  }

  /// Clean up
  void dispose() {
    _eventSubscription?.cancel();
    _eventSubscription = null;
    _currentCallId = null;
    _callDataCache.clear();
  }
}
