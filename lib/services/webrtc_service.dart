import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRTCService {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  bool _isCleanedUp = false;

  // Stream controllers
  final StreamController<MediaStream?> _remoteStreamController =
      StreamController<MediaStream?>.broadcast();
  final StreamController<RTCVideoRenderer?> _remoteRendererController =
      StreamController<RTCVideoRenderer?>.broadcast();
  final StreamController<RTCVideoRenderer?> _localRendererController =
      StreamController<RTCVideoRenderer?>.broadcast();
  final StreamController<bool> _callConnectedController =
      StreamController<bool>.broadcast();
  final StreamController<RTCIceCandidate> _iceCandidateController =
      StreamController<RTCIceCandidate>.broadcast();

  Stream<MediaStream?> get remoteStream => _remoteStreamController.stream;
  Stream<RTCVideoRenderer?> get remoteRenderer => _remoteRendererController.stream;
  Stream<RTCVideoRenderer?> get localRenderer => _localRendererController.stream;
  Stream<bool> get callConnected => _callConnectedController.stream;
  Stream<RTCIceCandidate> get onIceCandidate => _iceCandidateController.stream;

  RTCVideoRenderer? _remoteRenderer;
  RTCVideoRenderer? _localRenderer;

  RTCVideoRenderer? get remoteVideoRenderer => _remoteRenderer;
  RTCVideoRenderer? get localVideoRenderer => _localRenderer;

  // Buffer for ICE candidates that arrive before remote description is set
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;

  /// ICE servers configuration with STUN servers and free TURN relay
  static final Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
      {'urls': 'stun:stun3.l.google.com:19302'},
      {'urls': 'stun:stun4.l.google.com:19302'},
      {
        'urls': 'turn:openrelay.metered.ca:443',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:openrelay.metered.ca:80',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
    ],
  };

  /// Initialize the local media stream
  Future<MediaStream> initLocalStream({required bool video}) async {
    final Map<String, dynamic> constraints = {
      'audio': true,
      'video': video
          ? {
              'mandatory': {
                'minWidth': '640',
                'minHeight': '480',
                'minFrameRate': '30',
              },
              'facingMode': 'user',
            }
          : false,
    };

    _localStream = await navigator.mediaDevices.getUserMedia(constraints);

    // Initialize local renderer for video calls
    if (video) {
      _localRenderer = RTCVideoRenderer();
      await _localRenderer!.initialize();
      _localRenderer!.srcObject = _localStream;
      _localRendererController.add(_localRenderer);
    }

    return _localStream!;
  }

  /// Create a peer connection
  Future<RTCPeerConnection> createPeerConnection() async {
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();

    _peerConnection = await createPeerConnection_(_iceServers);

    // Add local stream tracks to peer connection
    if (_localStream != null) {
      for (var track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }
    }

    // Handle remote stream
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        _remoteStreamController.add(_remoteStream);

        // Create and initialize remote renderer
        if (_remoteRenderer == null) {
          _remoteRenderer = RTCVideoRenderer();
          _remoteRenderer!.initialize().then((_) {
            _remoteRenderer!.srcObject = _remoteStream;
            _remoteRendererController.add(_remoteRenderer);
          });
        } else {
          _remoteRenderer!.srcObject = _remoteStream;
          _remoteRendererController.add(_remoteRenderer);
        }
      }
    };

    // Handle ICE candidates - forward them via stream
    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      debugPrint('ICE candidate generated: ${candidate.candidate?.substring(0, 50)}...');
      _iceCandidateController.add(candidate);
    };

    // Handle connection state changes
    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('Connection state: $state');
      _callConnectedController.add(
        state == RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
    };

    _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
      debugPrint('ICE connection state: $state');
    };

    _peerConnection!.onIceGatheringState = (RTCIceGatheringState state) {
      debugPrint('ICE gathering state: $state');
    };

    return _peerConnection!;
  }

  /// Create an SDP offer
  Future<RTCSessionDescription> createOffer() async {
    final offer = await _peerConnection!.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': true,
    });
    await _peerConnection!.setLocalDescription(offer);
    return offer;
  }

  /// Create an SDP answer
  Future<RTCSessionDescription> createAnswer() async {
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);
    return answer;
  }

  /// Set remote description (offer or answer) and flush pending ICE candidates
  Future<void> setRemoteDescription(RTCSessionDescription desc) async {
    await _peerConnection!.setRemoteDescription(desc);
    _remoteDescriptionSet = true;
    debugPrint('Remote description set, flushing ${_pendingCandidates.length} pending ICE candidates');

    // Flush any ICE candidates that arrived before remote description
    for (final candidate in _pendingCandidates) {
      try {
        await _peerConnection!.addCandidate(candidate);
        debugPrint('Flushed pending ICE candidate');
      } catch (e) {
        debugPrint('Error flushing ICE candidate: $e');
      }
    }
    _pendingCandidates.clear();
  }

  /// Add a remote ICE candidate (buffers if remote description not set yet)
  Future<void> addIceCandidate(RTCIceCandidate candidate) async {
    if (_remoteDescriptionSet) {
      try {
        await _peerConnection!.addCandidate(candidate);
        debugPrint('ICE candidate added');
      } catch (e) {
        debugPrint('Error adding ICE candidate: $e');
      }
    } else {
      debugPrint('Buffering ICE candidate (remote description not set yet)');
      _pendingCandidates.add(candidate);
    }
  }

  /// Toggle audio mute
  Future<void> toggleMute() async {
    if (_localStream != null) {
      for (var track in _localStream!.getAudioTracks()) {
        track.enabled = !track.enabled;
      }
    }
  }

  /// Toggle video (for video calls)
  Future<void> toggleVideo() async {
    if (_localStream != null) {
      for (var track in _localStream!.getVideoTracks()) {
        track.enabled = !track.enabled;
      }
    }
  }

  /// Switch between front and back camera
  Future<void> switchCamera() async {
    if (_localStream != null) {
      final videoTrack = _localStream!.getVideoTracks().first;
      await Helper.switchCamera(videoTrack);
    }
  }

  /// Get current mute state
  bool get isMuted {
    if (_localStream == null) return false;
    final audioTracks = _localStream!.getAudioTracks();
    if (audioTracks.isEmpty) return false;
    return !audioTracks.first.enabled;
  }

  /// Get current video state
  bool get isVideoOff {
    if (_localStream == null) return true;
    final videoTracks = _localStream!.getVideoTracks();
    if (videoTracks.isEmpty) return true;
    return !videoTracks.first.enabled;
  }

  /// Clean up resources
  Future<void> hangup() async {
    if (_isCleanedUp) return;
    _isCleanedUp = true;

    _callConnectedController.add(false);

    // Stop local stream tracks
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream = null;

    // Dispose local renderer
    await _localRenderer?.dispose();
    _localRenderer = null;
    _localRendererController.add(null);

    // Close remote renderer
    await _remoteRenderer?.dispose();
    _remoteRenderer = null;
    _remoteStreamController.add(null);
    _remoteRendererController.add(null);

    // Close peer connection
    await _peerConnection?.close();
    _peerConnection = null;
    _remoteStream = null;

    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
  }

  void dispose() {
    hangup();
    _remoteStreamController.close();
    _localRendererController.close();
    _remoteRendererController.close();
    _callConnectedController.close();
    _iceCandidateController.close();
  }
}

/// Helper to create peer connection with config
Future<RTCPeerConnection> createPeerConnection_(
    Map<String, dynamic> configuration) async {
  return await createPeerConnection(configuration);
}
