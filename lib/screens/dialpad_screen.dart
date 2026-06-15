import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import '../models/user.dart';
import 'webrtc_call_screen.dart';

class DialpadScreen extends StatefulWidget {
  const DialpadScreen({super.key});

  @override
  State<DialpadScreen> createState() => _DialpadScreenState();
}

class _DialpadScreenState extends State<DialpadScreen> {
  final _numberController = TextEditingController();
  final _focusNode = FocusNode();
  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _numberController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onDigitPressed(String digit) {
    HapticFeedback.lightImpact();
    setState(() {
      _numberController.text += digit;
    });
  }

  void _onBackspace() {
    if (_numberController.text.isNotEmpty) {
      HapticFeedback.lightImpact();
      setState(() {
        _numberController.text =
            _numberController.text.substring(0, _numberController.text.length - 1);
      });
    }
  }

  void _onBackspaceLongPress() {
    HapticFeedback.mediumImpact();
    setState(() {
      _numberController.clear();
    });
  }

  Future<void> _makeNativeCall() async {
    final number = _numberController.text;
    if (number.isEmpty) return;

    final Uri phoneUri = Uri(scheme: 'tel', path: number);
    if (await canLaunchUrl(phoneUri)) {
      await launchUrl(phoneUri);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not launch phone dialer'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _makeVoipCall() async {
    final number = _numberController.text;
    if (number.isEmpty) return;

    // Try to find user by virtual number
    final token = await AuthService.getToken();
    if (token == null) return;

    try {
      final result = await ApiService.getUsers(token);
      if (result['success'] && result['users'] != null) {
        final users = result['users'] as List<User>;
        final match = users.firstWhere(
          (u) => u.virtualNumber == number || u.virtualNumber == '+$number',
          orElse: () => User(id: '', name: '', email: ''),
        );

        if (match.id.isNotEmpty) {
          if (!mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => WebRTCCallScreen(
                targetUserId: match.id,
                targetUserName: match.name,
                isVideo: false,
              ),
            ),
          );
          return;
        }
      }
    } catch (_) {}

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('No user found with this number'),
        backgroundColor: Colors.orange,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // Number display
            Expanded(
              flex: 2,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Number text field
                      SizedBox(
                        width: double.infinity,
                        child: Text(
                          _formatPhoneNumber(_numberController.text),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: _numberController.text.length > 12
                                ? 28
                                : 36,
                            fontWeight: FontWeight.w300,
                            letterSpacing: 2,
                            color: _numberController.text.isEmpty
                                ? Colors.grey[400]
                                : null,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Backspace button
                      if (_numberController.text.isNotEmpty)
                        GestureDetector(
                          onTap: _onBackspace,
                          onLongPress: _onBackspaceLongPress,
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.grey[200],
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.backspace_outlined,
                              color: Colors.grey[600],
                              size: 24,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),

            // Dial pad
            Expanded(
              flex: 4,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  children: [
                    _buildDialRow(['1', '2', '3'], primaryColor),
                    const SizedBox(height: 12),
                    _buildDialRow(['4', '5', '6'], primaryColor),
                    const SizedBox(height: 12),
                    _buildDialRow(['7', '8', '9'], primaryColor),
                    const SizedBox(height: 12),
                    _buildDialRow(['*', '0', '#'], primaryColor),
                  ],
                ),
              ),
            ),

            // Call buttons
            Expanded(
              flex: 2,
              child: Center(
                child: _numberController.text.isEmpty
                    ? _buildSingleCallButton(primaryColor)
                    : _buildCallOptionsRow(primaryColor),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSingleCallButton(Color primaryColor) {
    return GestureDetector(
      onTap: _makeNativeCall,
      child: Container(
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
        child: const Icon(Icons.phone, size: 36, color: Colors.white),
      ),
    );
  }

  Widget _buildCallOptionsRow(Color primaryColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // VoIP Call button
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: _makeVoipCall,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: primaryColor,
                  boxShadow: [
                    BoxShadow(
                      color: primaryColor.withAlpha(80),
                      blurRadius: 12,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Icon(Icons.wifi_calling, size: 30, color: Colors.white),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'VoIP Call',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: primaryColor,
              ),
            ),
          ],
        ),

        const SizedBox(width: 48),

        // Native Call button
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: _makeNativeCall,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.green,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.green.withAlpha(80),
                      blurRadius: 12,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Icon(Icons.phone, size: 30, color: Colors.white),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Phone Call',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Colors.green,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDialRow(List<String> digits, Color primaryColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: digits.map((digit) {
        final subtitle = _getDigitSubtitle(digit);
        return GestureDetector(
          onTap: () => _onDigitPressed(digit),
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.grey[50],
              border: Border.all(color: Colors.grey[200]!, width: 1),
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  digit,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w300,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 8,
                      letterSpacing: 2,
                      color: Colors.grey[500],
                    ),
                  ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  String? _getDigitSubtitle(String digit) {
    switch (digit) {
      case '2': return 'ABC';
      case '3': return 'DEF';
      case '4': return 'GHI';
      case '5': return 'JKL';
      case '6': return 'MNO';
      case '7': return 'PQRS';
      case '8': return 'TUV';
      case '9': return 'WXYZ';
      default: return null;
    }
  }

  String _formatPhoneNumber(String number) {
    if (number.isEmpty) return 'Enter number';
    return number;
  }
}
