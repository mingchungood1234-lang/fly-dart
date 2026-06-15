import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/signaling_service.dart';
import '../services/webrtc_service.dart';
import '../services/auth_service.dart';
import '../services/call_history_service.dart';

enum CallState {
  idle,
  calling,
  ringing,
  connecting,
  connected,
  ended,
}

class WebRTCCallScreen extends StatefulWidget {
  final String targetUserId;
  final String targetUserName;
  final bool isVideo;
  final bool isIncoming;
  final String? callerId;
  final String? callerName;

  const WebRTCCallScreen({
    super.key,
    required this.targetUserId,
    required this.targetUserName,
    this.isVideo = false,
    this.isIncoming = false,
    this.callerId,
    this.callerName,
  });

  @override
  State<WebRTCCallScreen> createState() => _WebRTCCallScreenState();
}

class _WebRTCCallScreenState extends State<WebRTCCallScreen>
    with SingleTickerProviderStateMixin {
  final WebRTCService _webrtcService = WebRTCService();
  // Use the singleton signaling service — do NOT create a new one
  final SignalingService _signalingService = SignalingService();

  CallState _callState = CallState.idle;
  bool _isMuted = false;
  bool _isVideoOff = false;
  bool _isSpeakerOn = true;
  bool _isScreenSharing = false;
  String? _currentUserId;
  bool _isCleanedUp = false;
  bool _hasRecordedHistory = false;
  bool _isInitializing = false;
  String? _errorMessage;
  StreamSubscription? _eventSubscription;
  StreamSubscription? _connectedSubscription;
  StreamSubscription? _iceCandidateSubscription;

  // Call duration timer
  Timer? _durationTimer;
  int _callDuration = 0;

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
    _ringAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _ringController, curve: Curves.easeInOut),
    );

    _initCall();
  }

  /// Get the remote peer's userId (who to send signals to)
  String get _remoteUserId {
    if (widget.isIncoming) {
      return widget.callerId ?? '';
    }
    return widget.targetUserId;
  }

  Future<void> _initCall() async {
    if (_isInitializing) return;
    _isInitializing = true;

    try {
      final user = await AuthService.getUser();
      if (user == null) {
        _showError('Not logged in. Please log in again.');
        return;
      }
      _currentUserId = user.id;

      // Initialize local stream (requests camera/mic permissions)
      await _webrtcService.initLocalStream(video: widget.isVideo);

      // Create peer connection
      await _webrtcService.createPeerConnection();

      // The signaling connection is already managed by HomeScreen (persistent).
      // We just need to verify it's connected and ensure registration.
      if (!_signalingService.isConnected) {
        // If somehow disconnected, reconnect (but this shouldn't happen)
        _signalingService.connect(_currentUserId!);
        // Wait briefly for connection
        await Future.delayed(const Duration(seconds: 2));
      }

      // Listen for signaling events
      _eventSubscription = _signalingService.events.listen(_handleSignalingEvent);

      // Listen for connection state changes
      _connectedSubscription = _webrtcService.callConnected.listen((connected) {
        if (connected && mounted) {
          setState(() => _callState = CallState.connected);
          _startDurationTimer();
        }
      });

      // Listen for ICE candidates from WebRTC and forward them via signaling
      _iceCandidateSubscription = _webrtcService.onIceCandidate.listen((candidate) {
        debugPrint('Forwarding ICE candidate to $_remoteUserId');
        _signalingService.sendSignal(
          targetId: _remoteUserId,
          signal: {
            'type': 'candidate',
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        );
      });

      if (widget.isIncoming) {
        setState(() => _callState = CallState.ringing);
      } else {
        setState(() => _callState = CallState.calling);
        _signalingService.callUser(
          callerId: _currentUserId!,
          callerName: user.name,
          targetId: widget.targetUserId,
          callType: widget.isVideo ? 'video' : 'audio',
        );
      }
    } catch (e) {
      debugPrint('Call init error: $e');
      _showError('Failed to start call: ${e.toString()}');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _errorMessage = message;
      _callState = CallState.ended;
    });
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) Navigator.pop(context);
    });
  }

  void _handleSignalingEvent(Map<String, dynamic> event) {
    final type = event['type'];
    final data = event['data'];

    switch (type) {
      case 'incoming_call':
        if (!widget.isIncoming) {
          setState(() => _callState = CallState.ringing);
        }
        break;

      case 'call_accepted':
        _onCallAccepted();
        break;

      case 'call_rejected':
        _onCallRejected();
        break;

      case 'call_offline':
        _onCallOffline(data);
        break;

      case 'call_ended':
        _onCallEnded();
        break;

      case 'signal':
        _handleSignal(data);
        break;
    }
  }

  void _handleSignal(Map<String, dynamic> data) async {
    try {
      final signal = data['signal'];
      final signalType = signal['type'];

      debugPrint('Received signal: $signalType from ${data['from']}');

      if (signalType == 'offer') {
        debugPrint('Processing SDP offer');
        final offer = RTCSessionDescription(
          signal['sdp'],
          signal['type'],
        );
        await _webrtcService.setRemoteDescription(offer);
        debugPrint('Creating and sending SDP answer');
        final answer = await _webrtcService.createAnswer();
        _signalingService.sendSignal(
          targetId: _remoteUserId,
          signal: {'type': 'answer', 'sdp': answer.sdp},
        );
        debugPrint('SDP answer sent');
      } else if (signalType == 'answer') {
        debugPrint('Processing SDP answer');
        final answer = RTCSessionDescription(
          signal['sdp'],
          signal['type'],
        );
        await _webrtcService.setRemoteDescription(answer);
        debugPrint('SDP answer applied');
      } else if (signalType == 'candidate') {
        final candidate = RTCIceCandidate(
          signal['candidate'],
          signal['sdpMid'],
          signal['sdpMLineIndex'],
        );
        debugPrint('Processing ICE candidate');
        await _webrtcService.addIceCandidate(candidate);
      }
    } catch (e) {
      debugPrint('Signal handling error: $e');
    }
  }

  void _onCallAccepted() async {
    setState(() => _callState = CallState.connecting);

    try {
      debugPrint('Call accepted, creating SDP offer');
      final offer = await _webrtcService.createOffer();
      _signalingService.sendSignal(
        targetId: _remoteUserId,
        signal: {'type': 'offer', 'sdp': offer.sdp},
      );
      debugPrint('SDP offer sent');
    } catch (e) {
      debugPrint('Error creating offer: $e');
      _signalingService.endCall(
        callerId: _currentUserId ?? '',
        targetId: _remoteUserId,
      );
      _showError('Failed to establish call');
    }
  }

  void _onCallRejected() {
    if (!_hasRecordedHistory) {
      _recordCallHistory(direction: CallDirection.outgoing, missed: true);
    }
    _safeCleanup();
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Call declined'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  void _onCallOffline(Map<String, dynamic>? data) {
    if (!_hasRecordedHistory) {
      _recordCallHistory(direction: CallDirection.outgoing, missed: true);
    }
    _safeCleanup();
    if (mounted) {
      final reason = data?['reason'] as String? ?? 'User is offline';
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(reason),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _onCallEnded() {
    if (!_hasRecordedHistory) {
      final dir = widget.isIncoming ? CallDirection.incoming : CallDirection.outgoing;
      _recordCallHistory(direction: dir);
    }
    _safeCleanup();
    if (mounted) Navigator.pop(context);
  }

  void _startDurationTimer() {
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) setState(() => _callDuration++);
    });
  }

  String _formatDuration(int seconds) {
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  void _acceptCall() {
    setState(() => _callState = CallState.connecting);
    _signalingService.acceptCall(
      callerId: widget.callerId ?? widget.targetUserId,
      targetId: _currentUserId!,
    );
  }

  void _rejectCall() {
    if (!_hasRecordedHistory) {
      _recordCallHistory(direction: CallDirection.missed);
    }
    _signalingService.rejectCall(
      callerId: widget.callerId ?? widget.targetUserId,
      targetId: _currentUserId!,
    );
    _safeCleanup();
    if (mounted) Navigator.pop(context);
  }

  void _endCall() {
    if (!_hasRecordedHistory) {
      final dir = widget.isIncoming ? CallDirection.incoming : CallDirection.outgoing;
      _recordCallHistory(direction: dir);
    }
    _signalingService.endCall(
      callerId: _currentUserId!,
      targetId: _remoteUserId,
    );
    _safeCleanup();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _toggleScreenSharing() async {
    try {
      if (_isScreenSharing) {
        await _webrtcService.stopScreenSharing();
        if (mounted) {
          setState(() => _isScreenSharing = false);
        }
      } else {
        final screenStream = await _webrtcService.startScreenSharing();
        if (screenStream != null && mounted) {
          setState(() => _isScreenSharing = true);
          
          // Re-negotiate peer connection with new screen track
          final offer = await _webrtcService.createOffer();
          _signalingService.sendSignal(
            targetId: _remoteUserId,
            signal: {'type': 'offer', 'sdp': offer.sdp},
          );
        }
      }
    } catch (e) {
      debugPrint('Error toggling screen sharing: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Screen sharing error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _recordCallHistory({
    required CallDirection direction,
    bool missed = false,
  }) {
    final displayName = widget.isIncoming
        ? (widget.callerName ?? 'Unknown')
        : widget.targetUserName;
    final contactId = widget.isIncoming
        ? (widget.callerId ?? '')
        : widget.targetUserId;

    _hasRecordedHistory = true;
    CallHistoryService.addRecord(CallRecord(
      contactId: contactId,
      contactName: displayName,
      direction: missed ? CallDirection.missed : direction,
      callType: widget.isVideo ? CallType.video : CallType.audio,
      timestamp: DateTime.now(),
      durationSeconds: _callDuration,
    ));
  }

  void _safeCleanup() {
    if (_isCleanedUp) return;
    _isCleanedUp = true;
    _durationTimer?.cancel();
    _eventSubscription?.cancel();
    _connectedSubscription?.cancel();
    _iceCandidateSubscription?.cancel();
    _webrtcService.hangup();
    // Do NOT disconnect the signaling service — it's managed by HomeScreen
  }

  @override
  void dispose() {
    _safeCleanup();
    _ringController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildCallContent()),
            _buildBottomControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildCallContent() {
    if (_callState == CallState.connected && widget.isVideo) {
      return _buildVideoView();
    }

    return _buildCallerInfo();
  }

  Widget _buildCallerInfo() {
    final displayName = widget.isIncoming
        ? (widget.callerName ?? 'Unknown Caller')
        : widget.targetUserName;

    final statusText = {
      CallState.idle: '',
      CallState.calling: 'Calling...',
      CallState.ringing: widget.isIncoming ? 'Incoming call...' : 'Ringing...',
      CallState.connecting: 'Connecting...',
      CallState.connected: _formatDuration(_callDuration),
      CallState.ended: 'Call ended',
    }[_callState];

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedBuilder(
            animation: _ringAnimation,
            builder: (context, child) {
              return Transform.scale(
                scale: _callState == CallState.ringing
                    ? _ringAnimation.value
                    : 1.0,
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _callState == CallState.ringing
                        ? Colors.orange.withAlpha(30)
                        : Theme.of(context).colorScheme.primary.withAlpha(30),
                    border: Border.all(
                      color: _callState == CallState.ringing
                          ? Colors.orange
                          : Theme.of(context).colorScheme.primary,
                      width: 3,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      displayName.isNotEmpty
                          ? displayName[0].toUpperCase()
                          : '?',
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                        color: _callState == CallState.ringing
                            ? Colors.orange
                            : Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          Text(
            displayName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _errorMessage!,
                style: const TextStyle(
                  color: Colors.red,
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
            )
          else
            Text(
              statusText ?? '',
              style: TextStyle(
                color: Colors.grey[400],
                fontSize: 16,
              ),
            ),
          if (!widget.isVideo && _callState == CallState.connected) ...[
            const SizedBox(height: 16),
            Icon(
              Icons.phone_in_talk,
              color: Colors.green[300],
              size: 32,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVideoView() {
    return Stack(
      children: [
        Center(
          child: _webrtcService.remoteVideoRenderer != null
              ? RTCVideoView(
                  _webrtcService.remoteVideoRenderer!,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              : const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
        ),
        if (_webrtcService.localVideoRenderer != null)
          Positioned(
            top: 16,
            right: 16,
            width: 120,
            height: 160,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white, width: 2),
              ),
              clipBehavior: Clip.antiAlias,
              child: RTCVideoView(
                _webrtcService.localVideoRenderer!,
                mirror: true,
              ),
            ),
          ),
        if (_callState == CallState.connected)
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _formatDuration(_callDuration),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBottomControls() {
    if (_callState == CallState.ended && _errorMessage != null) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
      decoration: const BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.isIncoming && _callState == CallState.ringing) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildCallButton(
                  icon: Icons.call_end,
                  label: 'Decline',
                  color: Colors.red,
                  onTap: _rejectCall,
                ),
                _buildCallButton(
                  icon: Icons.call,
                  label: 'Accept',
                  color: Colors.green,
                  onTap: _acceptCall,
                  large: true,
                ),
              ],
            ),
          ] else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildControlButton(
                  icon: _isMuted ? Icons.mic_off : Icons.mic,
                  label: _isMuted ? 'Unmute' : 'Mute',
                  active: !_isMuted,
                  onTap: () async {
                    await _webrtcService.toggleMute();
                    if (mounted) setState(() => _isMuted = !_isMuted);
                  },
                ),
                if (widget.isVideo)
                  _buildControlButton(
                    icon: _isVideoOff ? Icons.videocam_off : Icons.videocam,
                    label: _isVideoOff ? 'Camera On' : 'Camera Off',
                    active: !_isVideoOff,
                    onTap: () async {
                      await _webrtcService.toggleVideo();
                      if (mounted) {
                        setState(() => _isVideoOff = !_isVideoOff);
                      }
                    },
                  ),
                _buildControlButton(
                  icon: _isScreenSharing ? Icons.stop_screen_share : Icons.screen_share,
                  label: _isScreenSharing ? 'Stop Share' : 'Share Screen',
                  active: _isScreenSharing,
                  onTap: _toggleScreenSharing,
                ),
                _buildControlButton(
                  icon: Icons.volume_up,
                  label: _isSpeakerOn ? 'Speaker' : 'Earpiece',
                  active: _isSpeakerOn,
                  onTap: () {
                    if (mounted) {
                      setState(() => _isSpeakerOn = !_isSpeakerOn);
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 24),
            _buildCallButton(
              icon: Icons.call_end,
              label: 'End Call',
              color: Colors.red,
              onTap: _endCall,
              large: true,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? Colors.white.withAlpha(20) : Colors.grey[800],
            ),
            child: Icon(
              icon,
              color: active ? Colors.white : Colors.grey,
              size: 28,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : Colors.grey,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCallButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    bool large = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: large ? 72 : 56,
            height: large ? 72 : 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(
                  color: color.withAlpha(80),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(
              icon,
              color: Colors.white,
              size: large ? 36 : 28,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
