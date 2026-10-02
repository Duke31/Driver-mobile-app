import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'fcm_notification_service.dart';
import 'audio_service.dart';

class TelemetryService {
  static final TelemetryService _instance = TelemetryService._internal();
  factory TelemetryService() => _instance;
  TelemetryService._internal();

  final Battery _battery = Battery();
  final Connectivity _connectivity = Connectivity();
  final FcmNotificationService _fcm = FcmNotificationService();
  final AudioAlarmService _audio = AudioAlarmService();

  StreamSubscription<Position>? _positionSubscription;
  Timer? _telemetryTimer;

  Position? currentPosition;
  int batteryLevel = 100;
  bool isCharging = false;
  String networkType = 'wifi';
  String? currentDriverId;
  String? currentDriverName;
  String? currentVehicleLabel;
  bool isStreaming = false;

  // Active mission state & security lock
  bool hasActiveMission = false;
  String? activeMissionId;
  String? _lastAlertedMissionId;
  Function(Map<String, dynamic> mission)? onEmergencyAssigned;

  final ValueNotifier<Position?> positionNotifier = ValueNotifier<Position?>(null);
  final ValueNotifier<String> statusNotifier = ValueNotifier<String>('Standby');
  final ValueNotifier<bool> isOnDutyNotifier = ValueNotifier<bool>(true);

  bool get isOnDuty => isOnDutyNotifier.value;

  /// Check whether driver can safely toggle off duty
  bool get canGoOffDuty => !hasActiveMission;

  void setActiveMissionState(String? missionId) {
    if (missionId != null && missionId.isNotEmpty) {
      hasActiveMission = true;
      activeMissionId = missionId;
      isOnDutyNotifier.value = true; // Force On Duty while mission active
    } else {
      hasActiveMission = false;
      activeMissionId = null;
    }
  }

  Future<void> startTelemetry(
    String driverId, {
    String? driverName,
    String? vehicleLabel,
  }) async {
    currentDriverId = driverId;
    if (driverName != null) currentDriverName = driverName;
    if (vehicleLabel != null) currentVehicleLabel = vehicleLabel;
    isStreaming = true;
    isOnDutyNotifier.value = true;

    // 1. Keep ambulance screen awake on dash
    try {
      await WakelockPlus.enable();
    } catch (e) {
      debugPrint('Wakelock error: $e');
    }

    // 2. Register FCM token & show persistent foreground keep-alive notification
    try {
      await _fcm.registerDriver(driverId);
      await _fcm.showPersistentDutyNotification(
        driverName: currentDriverName ?? 'Ambulance Unit',
        vehicleLabel: currentVehicleLabel,
      );
    } catch (e) {
      debugPrint('FCM persistent notification error: $e');
    }

    // 3. Mark On Duty in database
    _setDutyInBackend(driverId, true);

    // 4. Request Location Permissions
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

    // 5. Get initial position
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      _handleNewPosition(pos);
    } catch (e) {
      debugPrint('Error getting initial position: $e');
    }

    // 6. Stream continuous location updates
    await _positionSubscription?.cancel();
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

    // 7. Periodic background telemetry sync & active emergency detector (every 6 seconds)
    _telemetryTimer?.cancel();
    _telemetryTimer = Timer.periodic(const Duration(seconds: 6), (_) async {
      await _syncTelemetryToBackend();
      await _checkForAssignedEmergencies();
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
    if (!isOnDuty && !hasActiveMission) return;

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

      // SECURITY DEFINER RPC: report_driver_telemetry
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

  /// PROACTIVE BACKGROUND EMERGENCY MONITOR:
  /// Even when app is minimized or phone is locked, this queries for assigned runs
  /// and loudly triggers siren + high-priority wake notification.
  Future<void> _checkForAssignedEmergencies() async {
    if (currentDriverId == null) return;

    try {
      final List<dynamic> list = await Supabase.instance.client
          .from('emergency_requests')
          .select('id, emergency_type, location_address, priority, status, contact_phone, patient_name, notes, created_at')
          .eq('driver_id', currentDriverId!)
          .order('created_at', ascending: false)
          .limit(10);

      Map<String, dynamic>? active;
      for (final item in list) {
        final st = (item['status'] ?? '').toString().toLowerCase().trim();
        final isFinished = st == 'completed' ||
            st.contains('cancel') ||
            st.contains('abort') ||
            st.contains('fail') ||
            st == 'declined';
        if (!isFinished) {
          active = Map<String, dynamic>.from(item as Map);
          break;
        }
      }

      if (active != null) {
        final reqId = active['id']?.toString();
        hasActiveMission = true;
        activeMissionId = reqId;

        // Force On Duty in memory and backend during active mission
        if (!isOnDuty) {
          isOnDutyNotifier.value = true;
          _setDutyInBackend(currentDriverId!, true);
        }

        // Check if this mission has already been alerted to the driver
        if (reqId != null && _lastAlertedMissionId != reqId) {
          _lastAlertedMissionId = reqId;

          final type = active['emergency_type']?.toString() ?? 'Emergency Run';
          final address = active['location_address']?.toString() ?? 'Location dispatched';
          final priority = active['priority']?.toString() ?? 'URGENT';

          // 1. Play loud siren alarm
          _audio.playDispatchAlarm();

          // 2. Trigger High-Priority Lock-Screen Wake Notification
          await _fcm.showEmergencyDispatchAlert(
            title: '🚨 PRIORITY $priority DISPATCH ASSIGNED!',
            body: '$type: $address. Tap to open mission console.',
            payload: reqId,
          );

          // 3. Update sticky foreground notification to indicate live mission
          await _fcm.showPersistentDutyNotification(
            driverName: currentDriverName ?? 'Ambulance Unit',
            vehicleLabel: '🚨 ACTIVE MISSION: $type',
          );

          // 4. Notify UI if mounted
          onEmergencyAssigned?.call(Map<String, dynamic>.from(active));
        }
      } else {
        // No active mission in progress
        if (hasActiveMission) {
          hasActiveMission = false;
          activeMissionId = null;
          _lastAlertedMissionId = null;
          // Restore standard persistent duty notification
          if (isOnDuty) {
            await _fcm.showPersistentDutyNotification(
              driverName: currentDriverName ?? 'Ambulance Unit',
              vehicleLabel: currentVehicleLabel,
            );
          }
        }
      }
    } catch (e) {
      debugPrint('Background emergency check note: $e');
    }
  }

  Future<void> _setDutyInBackend(String driverId, bool onDuty) async {
    try {
      await Supabase.instance.client.rpc('set_driver_duty_status', params: {
        'p_driver_id': driverId,
        'p_is_on_duty': onDuty,
      });
    } catch (_) {
      try {
        await Supabase.instance.client
            .from('drivers')
            .update({
              'active': onDuty,
              'duty_status': onDuty ? 'on_duty' : 'off_duty',
              'last_active_at': DateTime.now().toIso8601String(),
            })
            .eq('id', driverId);
      } catch (e) {
        debugPrint('set_driver_duty_status error: $e');
      }
    }
  }

  /// Feature B: Safe Toggle On Duty vs Off Duty with Security Guard
  Future<bool> toggleDuty(String driverId, {String? driverName, String? vehicleLabel}) async {
    if (isOnDuty) {
      // SECURITY GUARD: Never allow Off-Duty if an active mission is in progress!
      if (hasActiveMission) {
        debugPrint('SECURITY ENFORCEMENT: Driver cannot toggle off-duty while mission is active!');
        return false;
      }
      await stopTelemetry(setOffDuty: true);
      return true;
    } else {
      await startTelemetry(driverId, driverName: driverName, vehicleLabel: vehicleLabel);
      return true;
    }
  }

  Future<void> stopTelemetry({bool setOffDuty = true}) async {
    // SECURITY GUARD: If active mission is in progress, ignore request to go off-duty
    if (hasActiveMission) {
      debugPrint('SECURITY GUARD: Location telemetry transmission is locked ON during active emergency mission.');
      return;
    }

    isStreaming = false;
    if (setOffDuty) {
      isOnDutyNotifier.value = false;
    }
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _telemetryTimer?.cancel();
    _telemetryTimer = null;

    try {
      await WakelockPlus.disable();
    } catch (_) {}

    try {
      await _fcm.cancelPersistentDutyNotification();
    } catch (_) {}

    if (setOffDuty && currentDriverId != null) {
      _setDutyInBackend(currentDriverId!, false);
    }

    statusNotifier.value = 'Off Duty';
  }
}
