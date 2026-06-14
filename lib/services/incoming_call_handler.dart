import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
import 'signaling_service.dart';
import 'auth_service.dart';
import '../screens/webrtc_call_screen.dart';

/// Global incoming call handler that listens for calls at the app level.
/// Shows a full-screen incoming call overlay when a call arrives,
/// with a looping ringtone and vibration pattern — like a real phone.
class IncomingCallHandler {
  static final IncomingCallHandler _instance = IncomingCallHandler._();
  factory IncomingCallHandler() => _instance;
  IncomingCallHandler._();

  final SignalingService _signaling = SignalingService();
  StreamSubscription? _eventSubscription;
  bool _isHandlingCall = false;
  BuildContext? _appContext;

  // Ringtone player
  AudioPlayer? _ringtonePlayer;
  Timer? _vibrationTimer;
  bool _hasVibrator = false;

  /// Whether we're currently handling an incoming call
  bool get isHandlingCall => _isHandlingCall;

  /// Start listening for incoming calls. Call this from HomeScreen after login.
  void startListening(BuildContext context) {
    _appContext = context;
    _eventSubscription?.cancel();
    _eventSubscription = _signaling.events.listen(_onEvent);
    _checkVibrator();
    debugPrint('IncomingCallHandler: started listening');
  }

  /// Stop listening. Call this on logout.
  void stopListening() {
    _eventSubscription?.cancel();
    _eventSubscription = null;
    _appContext = null;
    stopRingtone();
    debugPrint('IncomingCallHandler: stopped listening');
  }

  /// Check if device has a vibrator (for vibration pattern)
  Future<void> _checkVibrator() async {
    _hasVibrator = await Vibration.hasVibrator();
  }

  /// Start playing the ringtone loop and vibration pattern
  Future<void> _startRingtone() async {
    // Play ringtone loop using a bundled asset
    try {
      _ringtonePlayer?.dispose();
      _ringtonePlayer = AudioPlayer();
      await _ringtonePlayer!.setReleaseMode(ReleaseMode.loop);
      await _ringtonePlayer!.setVolume(1.0);
      await _ringtonePlayer!.play(
        AssetSource('sounds/incoming_call.mp3'),
        volume: 1.0,
      );
    } catch (e) {
      debugPrint('Ringtone playback failed (add assets/sounds/incoming_call.mp3): $e');
      // No ringtone asset — rely on vibration only
    }

    // Start vibration pattern
    _startVibrationPattern();
  }

  /// Start a repeating vibration pattern: [vibrate, pause, vibrate, pause, ...]
  void _startVibrationPattern() {
    if (!_hasVibrator) return;

    // Pattern: vibrate 500ms, pause 300ms, vibrate 500ms, pause 1500ms (repeat from start)
    const pattern = [0, 500, 300, 500, 1500];

    try {
      // repeat: 0 means loop the pattern from index 0
      Vibration.vibrate(
        pattern: pattern,
        intensities: [0, 128, 0, 200, 0],
        repeat: 0,
      );
    } catch (e) {
      debugPrint('Vibration pattern error: $e');
      // Fallback to simple repeating vibration
      _vibrationTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        HapticFeedback.heavyImpact();
      });
    }
  }

  /// Stop ringtone and vibration
  void stopRingtone() {
    try {
      _ringtonePlayer?.stop();
      _ringtonePlayer?.dispose();
    } catch (_) {}
    _ringtonePlayer = null;

    _vibrationTimer?.cancel();
    _vibrationTimer = null;

    try {
      Vibration.cancel();
    } catch (_) {}
  }

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type'];

    if (type == 'incoming_call') {
      final data = event['data'] as Map<String, dynamic>;
      _handleIncomingCall(data);
    }
  }

  Future<void> _handleIncomingCall(Map<String, dynamic> data) async {
    if (_isHandlingCall) return;
    if (_appContext == null) return;

    final callerId = data['callerId'] as String?;
    final callerName = data['callerName'] as String? ?? 'Unknown';
    final callType = data['callType'] as String? ?? 'audio';

    if (callerId == null) return;

    // Set flag immediately to prevent race condition with duplicate events
    _isHandlingCall = true;

    // Prevent self-calls
    final user = await AuthService.getUser();
    if (user != null && user.id == callerId) {
      _isHandlingCall = false;
      return;
    }

    // Start ringtone and vibration
    _startRingtone();

    // Show incoming call overlay
    _showIncomingCallOverlay(
      callerId: callerId,
      callerName: callerName,
      isVideo: callType == 'video',
    );
  }

  void _showIncomingCallOverlay({
    required String callerId,
    required String callerName,
    required bool isVideo,
  }) {
    final context = _appContext;
    if (context == null) {
      _isHandlingCall = false;
      stopRingtone();
      return;
    }

    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        barrierDismissible: false,
        pageBuilder: (context, animation, secondaryAnimation) {
          return _IncomingCallScreen(
            callerId: callerId,
            callerName: callerName,
            isVideo: isVideo,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            )),
            child: child,
          );
        },
      ),
    ).then((_) {
      _isHandlingCall = false;
      stopRingtone();
    });
  }
}

/// Full-screen incoming call overlay with ringtone and vibration
class _IncomingCallScreen extends StatefulWidget {
  final String callerId;
  final String callerName;
  final bool isVideo;

  const _IncomingCallScreen({
    required this.callerId,
    required this.callerName,
    required this.isVideo,
  });

  @override
  State<_IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<_IncomingCallScreen>
    with SingleTickerProviderStateMixin {
  final SignalingService _signaling = SignalingService();
  final IncomingCallHandler _callHandler = IncomingCallHandler();
  String? _currentUserId;
  bool _answered = false;
  StreamSubscription? _eventSubscription;
  Timer? _timeoutTimer;

  // Ringing animation
  late AnimationController _ringController;
  late Animation<double> _ringAnimation;

  @override
  void initState() {
    super.initState();
    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
    _ringAnimation = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _ringController, curve: Curves.easeInOut),
    );
    _loadUser();
    _listenForCallEvents();
    // Auto-dismiss after 30 seconds if no response
    _timeoutTimer = Timer(const Duration(seconds: 30), () {
      if (mounted && !_answered) _dismiss('Call timed out');
    });
  }

  void _listenForCallEvents() {
    _eventSubscription = _signaling.events.listen((event) {
      final type = event['type'];
      if (type == 'call_ended' || type == 'call_rejected') {
        if (mounted && !_answered) _dismiss('Call ended');
      }
    });
  }

  Future<void> _loadUser() async {
    final user = await AuthService.getUser();
    if (mounted) {
      setState(() => _currentUserId = user?.id);
    }
  }

  bool get _hasUserId => _currentUserId != null && _currentUserId!.isNotEmpty;

  void _dismiss(String message) {
    _ringController.stop();
    _eventSubscription?.cancel();
    _timeoutTimer?.cancel();
    _callHandler.stopRingtone();
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    navigator.pop();
    if (messenger != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.orange),
      );
    }
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _timeoutTimer?.cancel();
    _callHandler.stopRingtone();
    _ringController.dispose();
    super.dispose();
  }

  void _acceptCall() async {
    if (_answered) return;
    if (!_hasUserId) {
      await _loadUser();
      if (!_hasUserId) return;
    }
    _answered = true;

    _ringController.stop();
    _callHandler.stopRingtone();
    _eventSubscription?.cancel();
    _timeoutTimer?.cancel();

    _signaling.acceptCall(
      callerId: widget.callerId,
      targetId: _currentUserId!,
    );

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => WebRTCCallScreen(
          targetUserId: widget.callerId,
          targetUserName: widget.callerName,
          isVideo: widget.isVideo,
          isIncoming: true,
          callerId: widget.callerId,
          callerName: widget.callerName,
        ),
      ),
    );
  }

  void _rejectCall() {
    _ringController.stop();
    _callHandler.stopRingtone();
    _eventSubscription?.cancel();
    _timeoutTimer?.cancel();

    _signaling.rejectCall(
      callerId: widget.callerId,
      targetId: _currentUserId ?? '',
    );

    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),

            // Caller avatar with ring animation
            AnimatedBuilder(
              animation: _ringAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: _ringAnimation.value,
                  child: Container(
                    width: 130,
                    height: 130,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.orange.withAlpha(30),
                      border: Border.all(
                        color: Colors.orange,
                        width: 3,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        widget.callerName.isNotEmpty
                            ? widget.callerName[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                          fontSize: 52,
                          fontWeight: FontWeight.bold,
                          color: Colors.orange,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 28),

            // Caller name
            Text(
              widget.callerName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),

            // Call type
            Text(
              widget.isVideo ? 'Video Call' : 'Voice Call',
              style: TextStyle(
                color: Colors.grey[400],
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 4),

            // Ringing text
            Text(
              'Incoming call...',
              style: TextStyle(
                color: Colors.orange[300],
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),

            const Spacer(flex: 3),

            // Accept / Reject buttons
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Reject
                  GestureDetector(
                    onTap: _rejectCall,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.red,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.red.withAlpha(80),
                                blurRadius: 16,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.call_end,
                            color: Colors.white,
                            size: 36,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Decline',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Accept
                  GestureDetector(
                    onTap: _acceptCall,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.green,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.green.withAlpha(80),
                                blurRadius: 16,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.call,
                            color: Colors.white,
                            size: 36,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Accept',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 64),
          ],
        ),
      ),
    );
  }
}
