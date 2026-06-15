# Fly Dart - VoIP Calling App

A cross-platform VoIP calling application built with Flutter, WebRTC, and Node.js. Supports voice calls, video calls, screen sharing, and push notifications.

## Features

| Feature | Android | iOS | Web |
|---------|---------|-----|-----|
| Voice Calls | ✅ | ✅ | ✅ |
| Video Calls | ✅ | ✅ | ✅ |
| Screen Sharing | ✅ | ❌¹ | ✅ |
| Push Notifications | ✅ | ✅² | ❌ |
| Background Calls (app killed) | ✅ | ✅² | ❌ |
| Contact Management | ✅ | ✅ | ✅ |
| Call History | ✅ | ✅ | ✅ |
| Dial Pad | ✅ | ✅ | ✅ |

¹ Requires Apple Developer Account ($99/year) for Broadcast Upload Extension  
² Requires Apple Developer Account ($99/year) for APNs certificate and CallKit

## Platform Requirements

### Android
- No additional requirements
- Screen sharing uses `MediaProjection` API (free)
- Background calls use foreground service (free)
- Push notifications via OneSignal (free tier)

### iOS
- **Apple Developer Account** ($99/year) required for:
  - Push notifications (APNs .p8 certificate)
  - Background calls (CallKit + VoIP push)
  - Screen sharing (Broadcast Upload Extension)
- Without paid account:
  - ✅ Voice/video calls work in foreground
  - ❌ No background calls when app is killed
  - ❌ No screen sharing

### Web
- No additional requirements
- Screen sharing built into browsers via `getDisplayMedia()` API
- No persistent background connection (tab must be open)
- No push notifications

## Getting Started

### Prerequisites

- Flutter SDK 3.x
- Node.js 18+ (for server)
- PostgreSQL database

### Server Setup

```bash
cd server
npm install
npm start
```

### Database Setup

```bash
cd server/db
# Run setup.js to initialize database
node setup.js
```

### Flutter App Setup

```bash
# Install dependencies
flutter pub get

# Run on Android
flutter run -d android

# Run on iOS (requires Xcode + paid Apple Developer account)
flutter run -d ios

# Run on web
flutter run -d chrome
```

### Environment Variables

Create `.env` file in `server/`:

```env
DATABASE_URL=postgresql://user:password@localhost:5432/flydart
JWT_SECRET=your-secret-key
ONESIGNAL_APP_ID=your-onesignal-app-id
ONESIGNAL_REST_API_KEY=your-onesignal-rest-api-key
```

## Architecture

### Client (Flutter)
- **WebRTC** - Peer-to-peer voice/video calls
- **Socket.IO** - Real-time signaling for call setup
- **OneSignal** - Push notifications for incoming calls
- **SharedPreferences** - Local auth token storage

### Server (Node.js)
- **Express** - REST API for auth and user management
- **Socket.IO** - Real-time signaling server
- **PostgreSQL** - User data and call history
- **JWT** - Authentication tokens

## Limitations

### iOS Without Apple Developer Account
- Calls only work when app is in foreground
- No screen sharing
- No background call notifications

### Web
- No persistent connection when tab is closed
- No push notifications
- Safari on iOS blocks screen sharing

## Building for Production

### Android

```bash
flutter build apk --release
```

### iOS

```bash
flutter build ios --release
# Then archive in Xcode
```

### Web

```bash
flutter build web --release
# Deploy build/web/ to any static hosting
```

## License

MIT
