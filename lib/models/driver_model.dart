class DriverModel {
  final String id;
  final String? userId;
  final String displayName;
  final String? vehicleLabel;
  final String? hospitalId;
  final String? hospitalName;
  final String? phone;
  final bool active;
  final String? status;
  final double? currentLat;
  final double? currentLng;
  final double? heading;
  final double? speed;
  final int? batteryLevel;
  final bool? isCharging;
  final String? networkType;

  DriverModel({
    required this.id,
    this.userId,
    required this.displayName,
    this.vehicleLabel,
    this.hospitalId,
    this.hospitalName,
    this.phone,
    this.active = true,
    this.status,
    this.currentLat,
    this.currentLng,
    this.heading,
    this.speed,
    this.batteryLevel,
    this.isCharging,
    this.networkType,
  });

  factory DriverModel.fromJson(Map<String, dynamic> json) {
    return DriverModel(
      id: (json['id'] ?? '') as String,
      userId: json['user_id'] as String?,
      displayName: (json['display_name'] as String?) ?? 'Ambulance Unit',
      vehicleLabel: json['vehicle_label'] as String?,
      hospitalId: json['hospital_id'] as String?,
      hospitalName: json['hospital_name'] as String?,
      phone: json['phone'] as String?,
      active: (json['active'] as bool?) ?? true,
      status: json['status'] as String?,
      currentLat: (json['current_lat'] as num?)?.toDouble(),
      currentLng: (json['current_lng'] as num?)?.toDouble(),
      heading: (json['heading'] as num?)?.toDouble(),
      speed: (json['speed'] as num?)?.toDouble(),
      batteryLevel: json['battery_level'] as int?,
      isCharging: json['is_charging'] as bool?,
      networkType: json['network_type'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'display_name': displayName,
      'vehicle_label': vehicleLabel,
      'hospital_id': hospitalId,
      'hospital_name': hospitalName,
      'phone': phone,
      'active': active,
      'status': status,
    };
  }
}
