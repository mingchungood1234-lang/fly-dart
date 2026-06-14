import 'dart:async';
import 'package:flutter/material.dart';
import '../models/user.dart';
import '../models/contact.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import '../services/contact_service.dart';
import '../services/signaling_service.dart';
import '../services/incoming_call_handler.dart';
import '../services/push_notification_service.dart';
import 'call_screen.dart';
import 'add_contact_screen.dart';
import 'webrtc_call_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  final SignalingService _signaling = SignalingService();
  final IncomingCallHandler _callHandler = IncomingCallHandler();
  final PushNotificationService _pushService = PushNotificationService();
  StreamSubscription? _pushCallSubscription;

  final List<Widget> _screens = [
    const CallScreen(),
    const _ContactsScreen(),
    const _ProfileScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _establishPersistentConnection();
  }

  /// Establish the persistent signaling connection and start listening
  /// for incoming calls — like Discord, the user is always "online".
  Future<void> _establishPersistentConnection() async {
    final user = await AuthService.getUser();
    if (user == null || !mounted) return;

    // Connect to signaling server (stays alive for the entire session)
    _signaling.connect(user.id);

    // Start listening for incoming calls globally
    _callHandler.startListening(context);

    // Initialize push notifications and register device token
    _pushService.registerAfterLogin();

    // Listen for incoming calls triggered by notification taps (app killed)
    _pushCallSubscription = _pushService.onIncomingCall.listen(_onPushNotificationCall);

    // Handle notification tap that arrived before this listener was ready
    final pending = _pushService.consumePendingNotificationCall();
    if (pending != null) {
      // Small delay to ensure the widget tree is fully built
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _onPushNotificationCall(pending);
      });
    }
  }

  /// Handle incoming call from a notification tap (app was killed/backgrounded)
  void _onPushNotificationCall(Map<String, dynamic> data) {
    if (!mounted) return;
    final callerId = data['callerId'] as String?;
    final callerName = data['callerName'] as String? ?? 'Unknown';
    final callType = data['callType'] as String? ?? 'audio';
    if (callerId == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => WebRTCCallScreen(
          targetUserId: callerId,
          targetUserName: callerName,
          isVideo: callType == 'video',
          isIncoming: true,
          callerId: callerId,
          callerName: callerName,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pushCallSubscription?.cancel();
    super.dispose();
  }

  Future<void> _logout() async {
    // Stop listening for incoming calls
    _callHandler.stopListening();

    // Unregister push token and disconnect
    await _pushService.unregisterToken();
    _pushCallSubscription?.cancel();

    // Disconnect the persistent signaling connection
    _signaling.disconnect();

    await AuthService.clearAuth();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/login');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PhoneCall'),
        centerTitle: true,
        elevation: 0.5,
        actions: [
          // Connection status indicator
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(
              _signaling.isConnected ? Icons.wifi : Icons.wifi_off,
              size: 18,
              color: _signaling.isConnected ? Colors.green : Colors.orange,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
            tooltip: 'Logout',
          ),
        ],
      ),
      body: _screens[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.phone),
            label: 'Calls',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.contacts),
            label: 'Contacts',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

// ==================== Contacts Screen ====================

class _ContactsScreen extends StatefulWidget {
  const _ContactsScreen();

  @override
  State<_ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<_ContactsScreen> {
  List<Contact> _contacts = [];
  List<Contact> _filteredContacts = [];
  bool _isLoading = true;
  String _searchQuery = '';
  final _searchController = TextEditingController();
  final SignalingService _signaling = SignalingService();
  Set<String> _onlineUserIds = {};
  StreamSubscription? _onlineUsersSubscription;
  // Map from virtual number → server user id, built when we fetch users
  final Map<String, String> _virtualToServerId = {};

  @override
  void initState() {
    super.initState();
    _loadContacts();
    _loadServerUserMapping();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text;
        _filterContacts();
      });
    });
    _onlineUserIds = _signaling.onlineUserIds;
    _onlineUsersSubscription = _signaling.onlineUsers.listen((ids) {
      if (mounted) setState(() => _onlineUserIds = ids);
    });
  }

  @override
  void dispose() {
    _onlineUsersSubscription?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// Fetch server users and build virtual number → server user ID mapping
  Future<void> _loadServerUserMapping() async {
    try {
      final token = await AuthService.getToken();
      if (token == null) return;
      final result = await ApiService.getUsers(token);
      if (result['success'] && result['users'] != null) {
        final users = result['users'] as List<User>;
        if (mounted) {
          setState(() {
            _virtualToServerId.clear();
            for (final user in users) {
              if (user.virtualNumber != null) {
                _virtualToServerId[user.virtualNumber!] = user.id;
              }
            }
          });
        }
      }
    } catch (_) {}
  }

  /// Check if a contact with the given virtual number is online
  bool _isContactOnline(String virtualNumber) {
    final serverId = _virtualToServerId[virtualNumber];
    if (serverId == null) return false;
    return _onlineUserIds.contains(serverId);
  }

  Future<void> _loadContacts() async {
    setState(() => _isLoading = true);
    _contacts = await ContactService.getContacts();
    _filterContacts();
    setState(() => _isLoading = false);
  }

  void _filterContacts() {
    if (_searchQuery.isEmpty) {
      _filteredContacts = List.from(_contacts);
    } else {
      final q = _searchQuery.toLowerCase();
      _filteredContacts = _contacts.where((c) {
        return c.name.toLowerCase().contains(q) ||
            c.virtualNumber.toLowerCase().contains(q) ||
            (c.email?.toLowerCase().contains(q) ?? false);
      }).toList();
    }
  }

  Future<void> _addContact() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const AddContactScreen()),
    );
    if (result == true) _loadContacts();
  }

  Future<void> _editContact(Contact contact) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddContactScreen(contact: contact),
      ),
    );
    if (result == true) _loadContacts();
  }

  Future<void> _deleteContact(Contact contact) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Contact'),
        content: Text('Remove "${contact.name}" from your contacts?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await ContactService.deleteContact(contact.id);
      _loadContacts();
    }
  }

  void _callContact(Contact contact, {required bool video}) {
    _lookupAndCall(contact.virtualNumber, contact.name, video: video);
  }

  Future<void> _lookupAndCall(
    String virtualNumber,
    String name, {
    required bool video,
  }) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Looking up user...'),
        duration: Duration(seconds: 1),
      ),
    );

    try {
      final token = await AuthService.getToken();
      if (token == null) return;

      final result = await ApiService.getUsers(token);
      if (result['success'] && result['users'] != null) {
        final users = result['users'] as List<User>;
        final match = users.firstWhere(
          (u) => u.virtualNumber == virtualNumber,
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
                isVideo: video,
              ),
            ),
          );
          return;
        }
      }
    } catch (_) {}

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$name is not registered on the server'),
        backgroundColor: Colors.orange,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Stack(
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search contacts...',
                  hintStyle: TextStyle(color: Colors.grey[400]),
                  prefixIcon: Icon(Icons.search, color: Colors.grey[400]),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 20),
                          onPressed: () => _searchController.clear(),
                        )
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Colors.grey[100],
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),
            ),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _filteredContacts.isEmpty
                      ? _buildEmptyState(primaryColor)
                      : RefreshIndicator(
                          onRefresh: _loadContacts,
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            itemCount: _filteredContacts.length,
                            itemBuilder: (context, index) {
                              final contact = _filteredContacts[index];
                              return _buildContactTile(contact, primaryColor);
                            },
                          ),
                        ),
            ),
          ],
        ),
        if (_filteredContacts.isNotEmpty)
          Positioned(
            bottom: 16,
            right: 16,
            child: FloatingActionButton(
              onPressed: _addContact,
              backgroundColor: primaryColor,
              child: const Icon(Icons.person_add, color: Colors.white),
            ),
          ),
      ],
    );
  }

  Widget _buildContactTile(Contact contact, Color primaryColor) {
    final isOnline = _isContactOnline(contact.virtualNumber);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Stack(
          children: [
            CircleAvatar(
              backgroundColor: primaryColor.withAlpha(30),
              child: Text(
                contact.name.isNotEmpty ? contact.name[0].toUpperCase() : '?',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: primaryColor,
                ),
              ),
            ),
            // Online indicator
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isOnline ? Colors.green : Colors.grey[400],
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
              ),
            ),
          ],
        ),
        title: Text(
          contact.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          contact.virtualNumber,
          style: TextStyle(
            color: Colors.grey[500],
            fontSize: 12,
            fontFamily: 'monospace',
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.phone, color: Colors.green),
              onPressed: () => _callContact(contact, video: false),
              tooltip: 'Audio Call',
            ),
            IconButton(
              icon: const Icon(Icons.videocam, color: Colors.blue),
              onPressed: () => _callContact(contact, video: true),
              tooltip: 'Video Call',
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'edit') {
                  _editContact(contact);
                } else if (value == 'delete') {
                  _deleteContact(contact);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'edit',
                  child: Row(
                    children: [
                      Icon(Icons.edit_outlined, size: 18),
                      SizedBox(width: 8),
                      Text('Edit'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline, size: 18, color: Colors.red),
                      SizedBox(width: 8),
                      Text('Delete', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              ],
              icon: Icon(Icons.more_vert, color: Colors.grey[500]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(Color primaryColor) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: primaryColor.withAlpha(10),
            ),
            child: Icon(
              Icons.person_add_outlined,
              size: 48,
              color: primaryColor.withAlpha(80),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'No contacts yet',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.grey[500],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add contacts by their virtual number\nto start calling them',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 14,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _addContact,
            icon: const Icon(Icons.person_add),
            label: const Text('Add Contact'),
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
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

// ==================== Profile Screen ====================

class _ProfileScreen extends StatefulWidget {
  const _ProfileScreen();

  @override
  State<_ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<_ProfileScreen> {
  User? _user;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    try {
      final token = await AuthService.getToken();
      if (token == null) {
        setState(() {
          _isLoading = false;
          _error = 'Not logged in';
        });
        return;
      }

      final result = await ApiService.getProfile(token);
      if (!mounted) return;

      if (result['success']) {
        setState(() {
          _user = result['user'];
          _isLoading = false;
        });
      } else {
        final cachedUser = await AuthService.getUser();
        setState(() {
          _user = cachedUser;
          _isLoading = false;
        });
      }
    } catch (e) {
      final cachedUser = await AuthService.getUser();
      setState(() {
        _user = cachedUser;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 50,
            backgroundColor:
                Theme.of(context).colorScheme.primary.withAlpha(30),
            child: Text(
              _user?.name.isNotEmpty == true
                  ? _user!.name[0].toUpperCase()
                  : '?',
              style: TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _user?.name ?? 'Unknown User',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(_user?.email ?? '',
              style: TextStyle(color: Colors.grey[500])),
          const SizedBox(height: 8),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withAlpha(20),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.phone,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  _user?.virtualNumber ?? 'No number',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: const TextStyle(color: Colors.orange, fontSize: 12)),
          ],
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  IncomingCallHandler().stopListening();
                  SignalingService().disconnect();
                  await AuthService.clearAuth();
                  if (!mounted) return;
                  Navigator.pushReplacementNamed(context, '/login');
                },
                icon: const Icon(Icons.logout, color: Colors.red),
                label: const Text('Logout',
                    style: TextStyle(color: Colors.red)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.red),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
