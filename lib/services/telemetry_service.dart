import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class TelemetryService {
  static final TelemetryService _instance = TelemetryService._internal();
  factory TelemetryService() => _instance;
  TelemetryService._internal();

  final Battery _battery = Battery();
  final Connectivity _connectivity = Connectivity();

  StreamSubscription<Position>? _positionSubscription;
  Timer? _telemetryTimer;

  Position? currentPosition;
  int batteryLevel = 100;
  bool isCharging = false;
  String networkType = 'wifi';
  String? currentDriverId;
  bool isStreaming = false;

  final ValueNotifier<Position?> positionNotifier = ValueNotifier<Position?>(null);
  final ValueNotifier<String> statusNotifier = ValueNotifier<String>('Standby');

  Future<void> startTelemetry(String driverId) async {
    currentDriverId = driverId;
    isStreaming = true;

    // 1. Keep ambulance screen awake
    try {
      await WakelockPlus.enable();
    } catch (e) {
      debugPrint('Wakelock error: $e');
    }

    // 2. Request Location Permissions
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        statusNotifier.value = 'Location permission denied';
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      statusNotifier.value = 'Location permissions permanently denied';
      return;
    }

    // 3. Get initial position
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      _handleNewPosition(pos);
    } catch (e) {
      debugPrint('Error getting initial position: $e');
    }

    // 4. Stream continuous location updates
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 5, // update every 5 meters
    );

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(_handleNewPosition, onError: (err) {
      debugPrint('Position stream error: $err');
      statusNotifier.value = 'GPS Signal Weak';
    });

    // 5. Periodic hardware telemetry sync (battery & network) every 10 seconds
    _telemetryTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      await _syncTelemetryToBackend();
    });

    statusNotifier.value = 'Transmitting Live Telemetry';
  }

  void _handleNewPosition(Position pos) {
    currentPosition = pos;
    positionNotifier.value = pos;
    _syncTelemetryToBackend();
  }

  Future<void> _syncTelemetryToBackend() async {
    if (currentDriverId == null || currentPosition == null) return;

    try {
      // Read battery
      try {
        batteryLevel = await _battery.batteryLevel;
        final state = await _battery.batteryState;
        isCharging = (state == BatteryState.charging || state == BatteryState.full);
      } catch (_) {}

      // Read connectivity
      try {
        final connResults = await _connectivity.checkConnectivity();
        if (connResults.contains(ConnectivityResult.wifi)) {
          networkType = 'wifi';
        } else if (connResults.contains(ConnectivityResult.mobile)) {
          networkType = 'cellular';
        } else {
          networkType = 'offline';
        }
      } catch (_) {}

      // SECURITY DEFINER RPC: Never updates table directly with anon role
      await Supabase.instance.client.rpc('report_driver_telemetry', params: {
        'p_driver_id': currentDriverId,
        'p_lat': currentPosition!.latitude,
        'p_lng': currentPosition!.longitude,
        'p_heading': currentPosition!.heading,
        'p_speed': currentPosition!.speed,
        'p_battery_level': batteryLevel,
        'p_is_charging': isCharging,
        'p_network_type': networkType,
      });

    } catch (e) {
      debugPrint('report_driver_telemetry RPC failed: $e');
    }
  }

  Future<void> stopTelemetry() async {
    isStreaming = false;
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _telemetryTimer?.cancel();
    _telemetryTimer = null;
    try {
      await WakelockPlus.disable();
    } catch (_) {}
    statusNotifier.value = 'Off Duty';
  }
}
