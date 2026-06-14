require('dotenv').config();
const express = require('express');
const http = require('http');
const path = require('path');
const cors = require('cors');
const pool = require('./db/connection');
const { Server } = require('socket.io');

const authRoutes = require('./routes/auth');
const { verifyToken } = require('./utils/jwt');

const app = express();
const server = http.createServer(app);
const PORT = process.env.PORT || 3000;

// Socket.IO signaling server
const io = new Server(server, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST'],
  },
});

// Middleware
app.use(cors());
app.use(express.json());

// Serve the web client
app.use('/web', express.static(path.join(__dirname, 'web')));

// Routes
app.use('/api/auth', authRoutes);

// List all users (for contacts & web client)
app.get('/api/users', async (req, res) => {
  try {
    const [rows] = await pool.query(
      'SELECT id, name, email, phone, virtual_number FROM users ORDER BY name ASC LIMIT 100'
    );
    res.json({ users: rows });
  } catch (error) {
    console.error('Error fetching users:', error);
    res.status(500).json({ message: 'Server error' });
  }
});

// Search users by virtual number or name
app.get('/api/users/search', async (req, res) => {
  try {
    const { q } = req.query;
    if (!q) return res.json({ users: [] });

    const searchTerm = `%${q}%`;
    const [rows] = await pool.query(
      `SELECT id, name, email, phone, virtual_number FROM users 
       WHERE name LIKE ? OR email LIKE ? OR virtual_number LIKE ?
       LIMIT 20`,
      [searchTerm, searchTerm, searchTerm]
    );
    res.json({ users: rows });
  } catch (error) {
    console.error('Error searching users:', error);
    res.status(500).json({ message: 'Server error' });
  }
});

// Health check
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', database: 'mysql', timestamp: new Date().toISOString() });
});

// Redirect root to web client
app.get('/', (req, res) => {
  res.redirect('/web');
});

// ========== Device Push Token Management ==========

// Auth middleware for protected endpoints
function authMiddleware(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ message: 'No token provided' });
  }
  try {
    const token = authHeader.split(' ')[1];
    const decoded = verifyToken(token);
    req.userId = decoded.id;
    next();
  } catch (error) {
    return res.status(401).json({ message: 'Invalid token' });
  }
}

// Register a device push token
app.post('/api/devices/register', authMiddleware, async (req, res) => {
  try {
    const { deviceToken, platform } = req.body;
    if (!deviceToken) {
      return res.status(400).json({ message: 'deviceToken is required' });
    }

    // Use the authenticated user's ID, not a client-provided userId
    const userId = req.userId;

    // Upsert: insert or update on duplicate token
    await pool.query(
      `INSERT INTO device_tokens (user_id, device_token, platform, updated_at)
       VALUES (?, ?, ?, NOW())
       ON DUPLICATE KEY UPDATE updated_at = NOW(), user_id = VALUES(user_id), platform = VALUES(platform)`,
      [userId, deviceToken, platform || 'unknown']
    );

    console.log(`Device token registered for user ${userId} (${platform})`);
    res.json({ success: true });
  } catch (error) {
    console.error('Device register error:', error);
    res.status(500).json({ message: 'Server error' });
  }
});

// Remove a device push token (on logout)
app.post('/api/devices/remove', authMiddleware, async (req, res) => {
  try {
    const { deviceToken } = req.body;
    if (!deviceToken) {
      return res.status(400).json({ message: 'deviceToken is required' });
    }

    // Only allow removing your own tokens
    await pool.query('DELETE FROM device_tokens WHERE device_token = ? AND user_id = ?', [deviceToken, req.userId]);
    console.log(`Device token removed for user ${req.userId}`);
    res.json({ success: true });
  } catch (error) {
    console.error('Device remove error:', error);
    res.status(500).json({ message: 'Server error' });
  }
});

// ========== WebRTC Signaling ==========

// Track connected users: userId -> { socketId, platform }
const connectedUsers = new Map();

// OneSignal push notification helper
async function sendPushNotification(targetUserId, payload) {
  const oneSignalAppId = process.env.ONESIGNAL_APP_ID;
  const oneSignalApiKey = process.env.ONESIGNAL_REST_API_KEY;

  if (!oneSignalAppId || !oneSignalApiKey) {
    console.log('Push notifications not configured (missing OneSignal credentials)');
    return;
  }

  try {
    // Get all device tokens for the target user
    const [tokens] = await pool.query(
      'SELECT device_token FROM device_tokens WHERE user_id = ?',
      [targetUserId]
    );

    if (tokens.length === 0) {
      console.log(`No device tokens found for user ${targetUserId}`);
      return;
    }

    const deviceIds = tokens.map(t => t.device_token);

    const message = {
      app_id: oneSignalAppId,
      include_player_ids: deviceIds,
      contents: { en: payload.body },
      headings: { en: payload.title },
      data: payload.data || {},
      // High priority for call notifications
      priority: 10,
      // iOS specific
      ios_badgeType: 'Increase',
      ios_badgeCount: 1,
    };

    const response = await fetch('https://onesignal.com/api/v1/notifications', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Basic ${oneSignalApiKey}`,
      },
      body: JSON.stringify(message),
    });

    const result = await response.json();
    if (result.id) {
      console.log(`Push notification sent to user ${targetUserId}: ${result.id}`);
    } else {
      console.log('Push notification response:', result);
    }
  } catch (error) {
    console.error('Push notification error:', error.message);
  }
}

io.on('connection', (socket) => {
  console.log('User connected:', socket.id);

  // Register user with their userId
  socket.on('register', (data) => {
    // Support both string and object formats
    const userId = typeof data === 'string' ? data : data.userId;
    const platform = typeof data === 'object' ? (data.platform || 'unknown') : 'unknown';

    connectedUsers.set(userId, { socketId: socket.id, platform });
    socket.data.userId = userId;
    socket.data.platform = platform;
    console.log(`User ${userId} registered (${platform}) with socket ${socket.id}`);

    // Broadcast updated online users list
    const onlineUserIds = Array.from(connectedUsers.keys());
    io.emit('online_users', onlineUserIds);
  });

  // Initiate a call
  socket.on('call_user', async (data) => {
    const { callerId, callerName, targetId, callType } = data;
    const target = connectedUsers.get(targetId);

    if (target) {
      io.to(target.socketId).emit('incoming_call', {
        callerId,
        callerName,
        callType,
      });
      console.log(`Call from ${callerId} to ${targetId} (${target.platform})`);
    } else {
      // User is not connected via socket — send push notification to wake them up
      console.log(`User ${targetId} not online, sending push notification`);
      
      // Send push notification to wake them up
      sendPushNotification(targetId, {
        title: callerName || 'Unknown Caller',
        body: callType === 'video' ? 'Incoming video call' : 'Incoming voice call',
        data: {
          type: 'incoming_call',
          callerId,
          callerName: callerName || 'Unknown',
          callType: callType || 'audio',
        },
      }).catch(() => {}); // Don't let push errors crash the handler
      // Notify caller that target is offline, but don't reject the call entirely
      socket.emit('call_offline', {
        reason: 'User is offline. Push notification sent.',
      });
    }
  });

  // Accept call
  socket.on('accept_call', (data) => {
    const { callerId, targetId } = data;
    const caller = connectedUsers.get(callerId);

    if (caller) {
      io.to(caller.socketId).emit('call_accepted', { targetId });
      console.log(`Call accepted: ${targetId} accepted from ${callerId}`);
    }
  });

  // Reject call
  socket.on('reject_call', (data) => {
    const { callerId, targetId } = data;
    const caller = connectedUsers.get(callerId);

    if (caller) {
      io.to(caller.socketId).emit('call_rejected', { targetId });
      console.log(`Call rejected: ${targetId} rejected from ${callerId}`);
    }
  });

  // End call
  socket.on('end_call', (data) => {
    const { callerId, targetId } = data;
    const target = connectedUsers.get(targetId);
    const caller = connectedUsers.get(callerId);

    if (target) {
      io.to(target.socketId).emit('call_ended', { callerId });
    }
    if (caller) {
      io.to(caller.socketId).emit('call_ended', { targetId });
    }
    console.log(`Call ended between ${callerId} and ${targetId}`);
  });

  // Relay WebRTC signals (SDP, ICE candidates)
  socket.on('signal', (data) => {
    const { to, signal } = data;
    const target = connectedUsers.get(to);

    if (target) {
      io.to(target.socketId).emit('signal', {
        from: socket.data.userId,
        signal,
      });
    }
  });

  // Handle disconnect
  socket.on('disconnect', () => {
    const userId = socket.data.userId;
    if (userId) {
      connectedUsers.delete(userId);
      console.log(`User ${userId} disconnected`);

      // Broadcast updated online users list
      const onlineUserIds = Array.from(connectedUsers.keys());
      io.emit('online_users', onlineUserIds);
    }
  });
});

// Initialize MySQL and start server
async function start() {
  try {
    // Test database connection
    const conn = await pool.getConnection();
    console.log('Connected to MySQL');

    // Create tables if not exist
    await conn.query(`
      CREATE TABLE IF NOT EXISTS users (
        id INT AUTO_INCREMENT PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        email VARCHAR(255) NOT NULL UNIQUE,
        password VARCHAR(255) NOT NULL,
        phone VARCHAR(20),
        virtual_number VARCHAR(20) NOT NULL UNIQUE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        INDEX idx_users_email (email),
        INDEX idx_users_virtual_number (virtual_number)
      )
    `);
    console.log('Users table ready');

    // Device tokens table for push notifications
    await conn.query(`
      CREATE TABLE IF NOT EXISTS device_tokens (
        id INT AUTO_INCREMENT PRIMARY KEY,
        user_id INT NOT NULL,
        device_token VARCHAR(500) NOT NULL,
        platform VARCHAR(20) DEFAULT 'unknown',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        UNIQUE KEY unique_token (device_token),
        INDEX idx_user_id (user_id),
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      )
    `);
    console.log('Device tokens table ready');

    conn.release();

    server.listen(PORT, () => {
      console.log(`Server running on port ${PORT}`);
      console.log(`Web client: http://localhost:${PORT}/web`);
      console.log(`API: http://localhost:${PORT}/api`);
      console.log('Signaling server ready');
      console.log('Push notifications:', process.env.ONESIGNAL_APP_ID ? 'Configured' : 'Not configured (set ONESIGNAL_APP_ID and ONESIGNAL_REST_API_KEY in .env)');
    });
  } catch (err) {
    console.error('MySQL connection error:', err.message);
    console.error('Make sure MySQL is running and check .env credentials');
    process.exit(1);
  }
}

start();

module.exports = { app, server, io };
