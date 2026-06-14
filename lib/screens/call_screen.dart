import 'package:flutter/material.dart';
import '../models/user.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import '../services/call_history_service.dart';
import 'webrtc_call_screen.dart';
import 'dialpad_screen.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  List<User> _allUsers = [];
  List<User> _filteredUsers = [];
  List<CallRecord> _recentCalls = [];
  User? _currentUser;
  bool _isLoading = true;
  String _searchQuery = '';
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadData();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text;
        _filterUsers();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      _currentUser = await AuthService.getUser();
      final token = await AuthService.getToken();
      if (token != null) {
        final result = await ApiService.getUsers(token);
        if (result['success'] && result['users'] != null) {
          final users = result['users'] as List<User>;
          setState(() {
            _allUsers = users
                .where((u) => u.id != _currentUser?.id)
                .toList();
            _filteredUsers = List.from(_allUsers);
          });
        }
      }
      _recentCalls = await CallHistoryService.getRecords();
    } catch (_) {}
    setState(() => _isLoading = false);
  }

  void _filterUsers() {
    if (_searchQuery.isEmpty) {
      _filteredUsers = List.from(_allUsers);
    } else {
      final q = _searchQuery.toLowerCase();
      _filteredUsers = _allUsers.where((u) {
        return u.name.toLowerCase().contains(q) ||
            u.email.toLowerCase().contains(q) ||
            (u.virtualNumber?.toLowerCase().contains(q) ?? false);
      }).toList();
    }
  }

  void _startCall(User user, {required bool video}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => WebRTCCallScreen(
          targetUserId: user.id,
          targetUserName: user.name,
          isVideo: video,
        ),
      ),
    ).then((_) => _loadData());
  }

  void _openDialpad() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const DialpadScreen()),
    );
  }

  String _formatCallDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    return '${mins}m ${secs}s';
  }

  String _formatCallTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    return _isLoading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _loadData,
            child: CustomScrollView(
              slivers: [
                // Greeting header
                SliverToBoxAdapter(child: _buildGreetingHeader(primaryColor)),

                // Search bar
                SliverToBoxAdapter(child: _buildSearchBar(primaryColor)),

                // Quick actions
                SliverToBoxAdapter(child: _buildQuickActions(primaryColor)),

                // Online contacts section
                if (_filteredUsers.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: _buildSectionHeader('Contacts', Icons.people),
                  ),
                  SliverToBoxAdapter(child: _buildContactsList(primaryColor)),
                ],

                // Recent calls section
                if (_recentCalls.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: _buildSectionHeader('Recent Calls', Icons.history),
                  ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => _buildRecentCallTile(
                        _recentCalls[index],
                        primaryColor,
                      ),
                      childCount: _recentCalls.length,
                    ),
                  ),
                ],

                // Empty state
                if (_allUsers.isEmpty && _recentCalls.isEmpty)
                  SliverFillRemaining(
                    child: _buildEmptyState(),
                  ),

                // Bottom padding
                const SliverToBoxAdapter(child: SizedBox(height: 80)),
              ],
            ),
          );
  }

  Widget _buildGreetingHeader(Color primaryColor) {
    final hour = DateTime.now().hour;
    String greeting;
    if (hour < 12) {
      greeting = 'Good Morning';
    } else if (hour < 17) {
      greeting = 'Good Afternoon';
    } else {
      greeting = 'Good Evening';
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Row(
        children: [
          // Avatar
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [primaryColor, primaryColor.withAlpha(180)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Center(
              child: Text(
                _currentUser?.name.isNotEmpty == true
                    ? _currentUser!.name[0].toUpperCase()
                    : '?',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$greeting,',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[500],
                    fontWeight: FontWeight.w400,
                  ),
                ),
                Text(
                  _currentUser?.name ?? 'User',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          // Virtual number badge
          if (_currentUser?.virtualNumber != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: primaryColor.withAlpha(15),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: primaryColor.withAlpha(40),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.phone, size: 12, color: primaryColor),
                  const SizedBox(width: 4),
                  Text(
                    _currentUser!.virtualNumber!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: primaryColor,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(Color primaryColor) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[100],
          borderRadius: BorderRadius.circular(16),
        ),
        child: TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Search contacts, numbers...',
            hintStyle: TextStyle(color: Colors.grey[400]),
            prefixIcon: Icon(Icons.search, color: Colors.grey[400]),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 20),
                    onPressed: () {
                      _searchController.clear();
                    },
                  )
                : null,
            border: InputBorder.none,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        ),
      ),
    );
  }

  Widget _buildQuickActions(Color primaryColor) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Row(
        children: [
          _buildActionChip(
            icon: Icons.dialpad,
            label: 'Dialpad',
            color: primaryColor,
            onTap: _openDialpad,
          ),
          const SizedBox(width: 12),
          _buildActionChip(
            icon: Icons.person_add_outlined,
            label: 'New Contact',
            color: Colors.teal,
            onTap: () {
              Navigator.pushNamed(context, '/register');
            },
          ),
          const SizedBox(width: 12),
          _buildActionChip(
            icon: Icons.refresh,
            label: 'Refresh',
            color: Colors.orange,
            onTap: _loadData,
          ),
        ],
      ),
    );
  }

  Widget _buildActionChip({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: color.withAlpha(12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withAlpha(30)),
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey[600]),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
              letterSpacing: 0.5,
            ),
          ),
          const Spacer(),
          if (title == 'Contacts')
            Text(
              '${_filteredUsers.length}',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[400],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildContactsList(Color primaryColor) {
    return SizedBox(
      height: 100,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: _filteredUsers.length,
        itemBuilder: (context, index) {
          final user = _filteredUsers[index];
          return _buildContactAvatar(user, primaryColor);
        },
      ),
    );
  }

  Widget _buildContactAvatar(User user, Color primaryColor) {
    return GestureDetector(
      onTap: () => _showCallOptions(user, primaryColor),
      onLongPress: () => _showContactDetails(user, primaryColor),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [
                        primaryColor.withAlpha(100),
                        primaryColor.withAlpha(50),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    border: Border.all(
                      color: primaryColor.withAlpha(60),
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      user.name.isNotEmpty
                          ? user.name[0].toUpperCase()
                          : '?',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: primaryColor,
                      ),
                    ),
                  ),
                ),
                // Online indicator
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.green,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              user.name.split(' ').first,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  void _showCallOptions(User user, Color primaryColor) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),

            // User info
            CircleAvatar(
              radius: 32,
              backgroundColor: primaryColor.withAlpha(20),
              child: Text(
                user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: primaryColor,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              user.name,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (user.virtualNumber != null) ...[
              const SizedBox(height: 4),
              Text(
                user.virtualNumber!,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[500],
                ),
              ),
            ],
            const SizedBox(height: 24),

            // Call options
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildCallOption(
                  icon: Icons.phone,
                  label: 'Audio Call',
                  color: Colors.green,
                  onTap: () {
                    Navigator.pop(context);
                    _startCall(user, video: false);
                  },
                ),
                _buildCallOption(
                  icon: Icons.videocam,
                  label: 'Video Call',
                  color: Colors.blue,
                  onTap: () {
                    Navigator.pop(context);
                    _startCall(user, video: true);
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildCallOption({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withAlpha(15),
              border: Border.all(color: color.withAlpha(40)),
            ),
            child: Icon(icon, color: color, size: 30),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  void _showContactDetails(User user, Color primaryColor) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 36,
              backgroundColor: primaryColor.withAlpha(20),
              child: Text(
                user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: primaryColor,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              user.name,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              user.email,
              style: TextStyle(color: Colors.grey[500]),
            ),
            if (user.virtualNumber != null) ...[
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: primaryColor.withAlpha(12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.phone, size: 14, color: primaryColor),
                    const SizedBox(width: 6),
                    Text(
                      user.virtualNumber!,
                      style: TextStyle(
                        color: primaryColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildCallOption(
                  icon: Icons.phone,
                  label: 'Audio',
                  color: Colors.green,
                  onTap: () {
                    Navigator.pop(context);
                    _startCall(user, video: false);
                  },
                ),
                _buildCallOption(
                  icon: Icons.videocam,
                  label: 'Video',
                  color: Colors.blue,
                  onTap: () {
                    Navigator.pop(context);
                    _startCall(user, video: true);
                  },
                ),
                _buildCallOption(
                  icon: Icons.message,
                  label: 'Message',
                  color: Colors.orange,
                  onTap: () {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Messaging coming soon'),
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentCallTile(CallRecord record, Color primaryColor) {
    IconData icon;
    Color iconColor;

    switch (record.direction) {
      case CallDirection.incoming:
        icon = Icons.call_received;
        iconColor = Colors.green;
        break;
      case CallDirection.outgoing:
        icon = Icons.call_made;
        iconColor = Colors.blue;
        break;
      case CallDirection.missed:
        icon = Icons.call_missed;
        iconColor = Colors.red;
        break;
    }

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      leading: Stack(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: primaryColor.withAlpha(15),
            child: Text(
              record.contactName.isNotEmpty
                  ? record.contactName[0].toUpperCase()
                  : '?',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: primaryColor,
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: iconColor.withAlpha(20),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: Icon(icon, size: 12, color: iconColor),
            ),
          ),
        ],
      ),
      title: Text(
        record.contactName,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: record.direction == CallDirection.missed
              ? Colors.red
              : null,
        ),
      ),
      subtitle: Row(
        children: [
          Icon(
            record.callType == CallType.video
                ? Icons.videocam
                : Icons.phone,
            size: 14,
            color: Colors.grey[400],
          ),
          const SizedBox(width: 4),
          if (record.durationSeconds > 0)
            Text(
              _formatCallDuration(record.durationSeconds),
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _formatCallTime(record.timestamp),
            style: TextStyle(
              fontSize: 12,
              color: record.direction == CallDirection.missed
                  ? Colors.red
                  : Colors.grey[500],
            ),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: () {
              final user = User(
                id: record.contactId,
                name: record.contactName,
                email: '',
                virtualNumber: record.contactVirtualNumber,
              );
              _startCall(user, video: record.callType == CallType.video);
            },
            child: Icon(
              record.callType == CallType.video
                  ? Icons.videocam
                  : Icons.phone,
              size: 18,
              color: primaryColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).colorScheme.primary.withAlpha(10),
            ),
            child: Icon(
              Icons.phone_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.primary.withAlpha(80),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Ready to call?',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Register more users or use the dialpad\nto make your first call',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 14,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _openDialpad,
            icon: const Icon(Icons.dialpad),
            label: const Text('Open Dialpad'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
