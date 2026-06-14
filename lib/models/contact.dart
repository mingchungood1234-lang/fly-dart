class Contact {
  final String id;
  final String name;
  final String virtualNumber;
  final String? email;
  final String? notes;
  final DateTime createdAt;

  Contact({
    required this.id,
    required this.name,
    required this.virtualNumber,
    this.email,
    this.notes,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  factory Contact.fromJson(Map<String, dynamic> json) {
    return Contact(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      virtualNumber: json['virtualNumber'] ?? '',
      email: json['email'],
      notes: json['notes'],
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'])
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'virtualNumber': virtualNumber,
        'email': email,
        'notes': notes,
        'createdAt': createdAt.toIso8601String(),
      };
}
