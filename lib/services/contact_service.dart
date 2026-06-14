import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/contact.dart';

class ContactService {
  static const String _contactsKey = 'local_contacts';

  /// Get all stored contacts
  static Future<List<Contact>> getContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_contactsKey);
    if (jsonString == null) return [];

    final jsonList = jsonDecode(jsonString) as List;
    final contacts = jsonList.map((json) => Contact.fromJson(json)).toList();
    contacts.sort((a, b) => a.name.compareTo(b.name));
    return contacts;
  }

  /// Add a new contact
  static Future<void> addContact(Contact contact) async {
    final contacts = await getContacts();
    contacts.add(contact);
    await _saveContacts(contacts);
  }

  /// Update an existing contact
  static Future<void> updateContact(Contact updated) async {
    final contacts = await getContacts();
    final index = contacts.indexWhere((c) => c.id == updated.id);
    if (index != -1) {
      contacts[index] = updated;
      await _saveContacts(contacts);
    }
  }

  /// Delete a contact by id
  static Future<void> deleteContact(String id) async {
    final contacts = await getContacts();
    contacts.removeWhere((c) => c.id == id);
    await _saveContacts(contacts);
  }

  /// Find a contact by virtual number
  static Future<Contact?> findByNumber(String number) async {
    final contacts = await getContacts();
    try {
      return contacts.firstWhere((c) => c.virtualNumber == number);
    } catch (_) {
      return null;
    }
  }

  /// Search contacts by name or number
  static Future<List<Contact>> search(String query) async {
    final contacts = await getContacts();
    if (query.isEmpty) return contacts;
    final q = query.toLowerCase();
    return contacts.where((c) {
      return c.name.toLowerCase().contains(q) ||
          c.virtualNumber.toLowerCase().contains(q) ||
          (c.email?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  static Future<void> _saveContacts(List<Contact> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = contacts.map((c) => c.toJson()).toList();
    await prefs.setString(_contactsKey, jsonEncode(jsonList));
  }
}
