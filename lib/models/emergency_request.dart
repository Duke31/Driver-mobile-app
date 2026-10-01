class EmergencyRequestModel {
  final String id;
  final String? patientAddress;
  final String? origin;
  final double? patientLat;
  final double? patientLng;
  final String? emergencyType;
  final String status;
  final String createdAt;
  final String? completedAt;
  final String? hospitalId;
  final String? driverId;
  final String? driverName;
  final String? driverPhone;
  final String? notes;
  final String? contactPhone;
  final String? patientAgeBand;
  final String? priority;
  final Map<String, dynamic>? hospital;

  EmergencyRequestModel({
    required this.id,
    this.patientAddress,
    this.origin,
    this.patientLat,
    this.patientLng,
    this.emergencyType,
    required this.status,
    required this.createdAt,
    this.completedAt,
    this.hospitalId,
    this.driverId,
    this.driverName,
    this.driverPhone,
    this.notes,
    this.contactPhone,
    this.patientAgeBand,
    this.priority,
    this.hospital,
  });

  static double? _parseDouble(dynamic val) {
    if (val == null) return null;
    if (val is num) return val.toDouble();
    if (val is String) return double.tryParse(val);
    return null;
  }

  static Map<String, dynamic>? _parseHospital(dynamic raw) {
    if (raw == null) return null;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is List && raw.isNotEmpty && raw.first is Map) {
      return Map<String, dynamic>.from(raw.first as Map);
    }
    return null;
  }

  factory EmergencyRequestModel.fromJson(Map<String, dynamic> json) {
    final rawHospital = json['hospital'] ?? json['hospitals'];

    return EmergencyRequestModel(
      id: (json['id'] ?? '') as String,
      patientAddress: json['patient_address'] as String?,
      origin: json['origin'] as String?,
      patientLat: _parseDouble(json['patient_lat']),
      patientLng: _parseDouble(json['patient_lng']),
      emergencyType: json['emergency_type'] as String?,
      status: (json['status'] as String?) ?? 'assigned',
      createdAt: (json['created_at'] as String?) ?? '',
      completedAt: json['completed_at'] as String?,
      hospitalId: json['hospital_id'] as String?,
      driverId: json['driver_id'] as String?,
      driverName: json['driver_name'] as String?,
      driverPhone: json['driver_phone'] as String?,
      notes: json['notes'] as String?,
      contactPhone: json['contact_phone'] as String?,
      patientAgeBand: json['patient_age_band'] as String?,
      priority: json['priority']?.toString(),
      hospital: _parseHospital(rawHospital),
    );
  }

  String get hospitalName {
    if (hospital != null && hospital!['name'] != null) {
      return hospital!['name'] as String;
    }
    return 'Receiving Hospital';
  }

  String? get hospitalPhone {
    if (hospital != null) {
      final p = hospital!['intake_phone'] ?? hospital!['phone'] ?? hospital!['contact_phone'];
      return p?.toString();
    }
    return null;
  }

  int? get hospitalCapacity {
    if (hospital != null && hospital!['available_capacity'] != null) {
      final cap = hospital!['available_capacity'];
      if (cap is num) return cap.toInt();
      if (cap is String) return int.tryParse(cap);
    }
    return null;
  }

  double? get hospitalLat => _parseDouble(hospital?['lat']);
  double? get hospitalLng => _parseDouble(hospital?['lng']);
  String? get hospitalAddress => hospital?['address'] as String?;

  /// Indicates whether the ambulance is already on its way to the hospital
  bool get isEnRouteToHospital {
    final s = status.toLowerCase();
    return s.contains('en route to hospital') || s.contains('to hospital');
  }

  /// Indicates whether the ambulance has arrived at the hospital
  bool get isArrivedAtHospital {
    final s = status.toLowerCase();
    return s.contains('arrived / intake') || s.contains('arrived at hospital');
  }
}
