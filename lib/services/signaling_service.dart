import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../config/env.dart';

/// Singleton signaling service that maintains a persistent Socket.IO connection.
/// Like Discord — the connection stays alive across the entire app session
/// so the user can receive incoming calls from any screen.
class SignalingService {
  // Singleton
  static final SignalingService _instance = SignalingService._internal();
  factory SignalingService() => _instance;
  SignalingService._internal();

  io.Socket? _socket;
  String? _currentUserId;
  bool _isConnecting = false;
  bool _intentionalDisconnect = false;

  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Stream of signaling events (incoming_call, call_accepted, etc.)
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  // ========== Online Users Tracking ==========
  final Set<String> _onlineUserIds = {};
  final StreamController<Set<String>> _onlineUsersController =
      StreamController<Set<String>>.broadcast();

  /// Stream of online user ID sets — emits whenever the online list changes
  Stream<Set<String>> get onlineUsers => _onlineUsersController.stream;

  /// Current set of online user IDs
  Set<String> get onlineUserIds => Set.unmodifiable(_onlineUserIds);

  /// Check if a specific user is online
  bool isUserOnline(String userId) => _onlineUserIds.contains(userId);

  /// Whether the socket is currently connected
  bool get isConnected => _socket?.connected ?? false;

  /// Whether we have an active user session
  bool get hasSession => _currentUserId != null;

  /// Connect to the signaling server (persists across app session)
  void connect(String userId) {
    if (_isConnecting) return;
    if (isConnected && _currentUserId == userId) {
      debugPrint('Signaling already connected for $userId');
      return;
    }

    _intentionalDisconnect = false;
    _currentUserId = userId;
    _isConnecting = true;

    // Dispose old socket if reconnecting with different userId
    _disposeSocket();

    try {
      final serverUrl = Env.apiBaseUrl.replaceAll('/api', '');
      debugPrint('Signaling connecting to: $serverUrl (userId: $userId)');

      _socket = io.io(
        serverUrl,
        io.OptionBuilder()
            .setTransports(['websocket', 'polling'])
            .enableAutoConnect()
            .enableReconnection()
            .setReconnectionDelay(1000)
            .setReconnectionAttempts(-1) // Infinite reconnection attempts
            .build(),
      );

      _socket!.onConnect((_) {
        debugPrint('Signaling connected');
        _isConnecting = false;
        // Re-register on every connect (including reconnections)
        _register();
      });

      _socket!.onDisconnect((_) {
        debugPrint('Signaling disconnected');
        _isConnecting = false;
        if (!_intentionalDisconnect && _currentUserId != null) {
          debugPrint('Signaling will auto-reconnect...');
        }
      });

      _socket!.onConnectError((error) {
        debugPrint('Signaling connect error: $error');
        _isConnecting = false;
      });

      _socket!.onError((error) {
        debugPrint('Signaling error: $error');
      });

      _socket!.onReconnect((_) {
        debugPrint('Signaling reconnected');
        _register();
      });

      _socket!.onReconnectAttempt((attempt) {
        debugPrint('Signaling reconnect attempt: $attempt');
      });

      _socket!.onReconnectError((error) {
        debugPrint('Signaling reconnect error: $error');
      });

      _socket!.onReconnectFailed((_) {
        debugPrint('Signaling reconnect failed after all attempts');
      });

      // Listen for call events
      _socket!.on('incoming_call', (data) {
        debugPrint('Received incoming_call: $data');
        _eventController.add({'type': 'incoming_call', 'data': data});
      });

      _socket!.on('call_accepted', (data) {
        debugPrint('Received call_accepted: $data');
        _eventController.add({'type': 'call_accepted', 'data': data});
      });

      _socket!.on('call_rejected', (data) {
        debugPrint('Received call_rejected: $data');
        _eventController.add({'type': 'call_rejected', 'data': data});
      });

      _socket!.on('call_ended', (data) {
        debugPrint('Received call_ended: $data');
        _eventController.add({'type': 'call_ended', 'data': data});
      });

      _socket!.on('signal', (data) {
        _eventController.add({'type': 'signal', 'data': data});
      });

      _socket!.on('online_users', (data) {
        _eventController.add({'type': 'online_users', 'data': data});
        _updateOnlineUsers(data);
      });
    } catch (e) {
      debugPrint('Signaling connect failed: $e');
      _isConnecting = false;
    }
  }

  /// Register the current userId with the server
  void _register() {
    if (_socket != null && _currentUserId != null && _socket!.connected) {
      _socket!.emit('register', _currentUserId);
      debugPrint('Registered userId: $_currentUserId');
    }
  }

  /// Initiate a call to another user
  void callUser({
    required String callerId,
    required String callerName,
    required String targetId,
    required String callType,
  }) {
    _socket?.emit('call_user', {
      'callerId': callerId,
      'callerName': callerName,
      'targetId': targetId,
      'callType': callType,
    });
  }

  /// Accept an incoming call
  void acceptCall({
    required String callerId,
    required String targetId,
  }) {
    _socket?.emit('accept_call', {
      'callerId': callerId,
      'targetId': targetId,
    });
  }

  /// Reject an incoming call
  void rejectCall({
    required String callerId,
    required String targetId,
  }) {
    _socket?.emit('reject_call', {
      'callerId': callerId,
      'targetId': targetId,
    });
  }

  /// End an active call
  void endCall({
    required String callerId,
    required String targetId,
  }) {
    _socket?.emit('end_call', {
      'callerId': callerId,
      'targetId': targetId,
    });
  }

  /// Send SDP/ICE signals
  void sendSignal({
    required String targetId,
    required Map<String, dynamic> signal,
  }) {
    _socket?.emit('signal', {
      'to': targetId,
      'signal': signal,
    });
  }

  /// Update the set of online user IDs from server broadcast
  void _updateOnlineUsers(dynamic data) {
    try {
      final List<dynamic> userIdList = data as List<dynamic>;
      _onlineUserIds
        ..clear()
        ..addAll(userIdList.map((id) => id.toString()));
      // Remove self from the list
      if (_currentUserId != null) {
        _onlineUserIds.remove(_currentUserId);
      }
      if (!_onlineUsersController.isClosed) {
        _onlineUsersController.add(Set.unmodifiable(_onlineUserIds));
      }
      debugPrint('Online users updated: ${_onlineUserIds.length} users');
    } catch (e) {
      debugPrint('Error updating online users: $e');
    }
  }

  /// Disconnect from signaling server (called on logout)
  void disconnect() {
    _intentionalDisconnect = true;
    _currentUserId = null;
    _disposeSocket();
  }

  /// Dispose just the socket without closing the event stream
  void _disposeSocket() {
    try {
      _socket?.disconnect();
      _socket?.dispose();
    } catch (e) {
      debugPrint('Signaling dispose error: $e');
    }
    _socket = null;
    _isConnecting = false;
  }

  /// Clean up everything (called on app dispose)
  void dispose() {
    _intentionalDisconnect = true;
    _currentUserId = null;
    _disposeSocket();
    if (!_eventController.isClosed) {
      _eventController.close();
    }
    if (!_onlineUsersController.isClosed) {
      _onlineUsersController.close();
    }
  }
}
