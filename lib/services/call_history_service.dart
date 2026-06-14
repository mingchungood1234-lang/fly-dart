import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

enum CallDirection { incoming, outgoing, missed }
enum CallType { audio, video }

class CallRecord {
  final String contactId;
  final String contactName;
  final String? contactVirtualNumber;
  final CallDirection direction;
  final CallType callType;
  final DateTime timestamp;
  final int durationSeconds;

  CallRecord({
    required this.contactId,
    required this.contactName,
    this.contactVirtualNumber,
    required this.direction,
    required this.callType,
    required this.timestamp,
    this.durationSeconds = 0,
  });

  factory CallRecord.fromJson(Map<String, dynamic> json) {
    return CallRecord(
      contactId: json['contactId'] ?? '',
      contactName: json['contactName'] ?? '',
      contactVirtualNumber: json['contactVirtualNumber'],
      direction: CallDirection.values.firstWhere(
        (e) => e.name == json['direction'],
        orElse: () => CallDirection.outgoing,
      ),
      callType: CallType.values.firstWhere(
        (e) => e.name == json['callType'],
        orElse: () => CallType.audio,
      ),
      timestamp: DateTime.parse(json['timestamp']),
      durationSeconds: json['durationSeconds'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'contactId': contactId,
        'contactName': contactName,
        'contactVirtualNumber': contactVirtualNumber,
        'direction': direction.name,
        'callType': callType.name,
        'timestamp': timestamp.toIso8601String(),
        'durationSeconds': durationSeconds,
      };
}

class CallHistoryService {
  static const String _historyKey = 'call_history';
  static const int _maxRecords = 50;

  /// Add a call record to history
  static Future<void> addRecord(CallRecord record) async {
    final prefs = await SharedPreferences.getInstance();
    final records = await getRecords();

    // Prevent duplicate consecutive calls to same contact
    if (records.isNotEmpty &&
        records.first.contactId == record.contactId &&
        records.first.timestamp.difference(record.timestamp).abs().inSeconds < 5) {
      return;
    }

    records.insert(0, record);

    // Trim to max size
    if (records.length > _maxRecords) {
      records.removeRange(_maxRecords, records.length);
    }

    final jsonList = records.map((r) => r.toJson()).toList();
    await prefs.setString(_historyKey, jsonEncode(jsonList));
  }

  /// Get all call records (most recent first)
  static Future<List<CallRecord>> getRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_historyKey);
    if (jsonString == null) return [];

    final jsonList = jsonDecode(jsonString) as List;
    return jsonList.map((json) => CallRecord.fromJson(json)).toList();
  }

  /// Clear all call history
  static Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
  }

  /// Get records for a specific contact
  static Future<List<CallRecord>> getRecordsForContact(String contactId) async {
    final records = await getRecords();
    return records.where((r) => r.contactId == contactId).toList();
  }
}
