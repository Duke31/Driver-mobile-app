import 'package:flutter/services.dart';
import '../services/fcm_notification_service.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/driver_model.dart';
import '../models/emergency_request.dart';
import '../services/telemetry_service.dart';
import '../services/audio_service.dart';
import 'active_job_tab.dart';
import 'available_jobs_tab.dart';
import 'job_history_tab.dart';
import 'driver_login_screen.dart';

class MainDriverScreen extends StatefulWidget {
  final DriverModel driver;

  const MainDriverScreen({super.key, required this.driver});

  @override
  State<MainDriverScreen> createState() => _MainDriverScreenState();
}

class _MainDriverScreenState extends State<MainDriverScreen> {
  int _currentTabIndex = 0;
  final TelemetryService _telemetry = TelemetryService();
  final AudioAlarmService _audio = AudioAlarmService();
  final FcmNotificationService _fcm = FcmNotificationService();
  Timer? _missionPollTimer;

  EmergencyRequestModel? _activeMission;
  List<EmergencyRequestModel> _availableJobs = [];
  List<EmergencyRequestModel> _jobHistory = [];

  bool _isLoadingActive = true;
  bool _isLoadingAvailable = true;
  bool _isLoadingHistory = false;

  String? _activeFetchError;
  String? _availableFetchError;

  bool _isAudioMuted = false;
  String? _incomingAlertMessage;
  RealtimeChannel? _subscription;

  @override
  void initState() {
    super.initState();
    _startTelemetry();
    _fetchActiveMission();
    _fetchAvailableJobs();
    _fetchJobHistory();
    _setupRealtimeDispatchChannel();

    // Fast polling fallback (every 3 seconds) ensuring instant assignment detection
    _missionPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) {
        _fetchActiveMission(silent: true);
      }
    });

    // Listen for proactive background emergency detection from TelemetryService
    _telemetry.onEmergencyAssigned = (missionMap) {
      if (mounted) {
        try {
          final mission = EmergencyRequestModel.fromJson(missionMap);
          final bool isNew = _activeMission == null || _activeMission!.id != mission.id;
          setState(() {
            _activeMission = mission;
            _currentTabIndex = 0; // Focus directly on Active Mission
            _incomingAlertMessage = '🚨 EMERGENCY DISPATCH: ${mission.emergencyType ?? "Priority Run"} assigned to your unit!';
          });
          _telemetry.setActiveMissionState(mission.id);
          if (isNew) {
            _triggerAlarm(
              '🚨 DISPATCH: Emergency run assigned to your unit!',
              requestId: mission.id,
              address: mission.patientAddress,
              type: mission.emergencyType,
            );
          }
        } catch (e) {
          debugPrint('Error parsing assigned mission from background telemetry: $e');
        }
      }
    };
  }

  @override
  void dispose() {
    _missionPollTimer?.cancel();
    _subscription?.unsubscribe();
    _audio.stopAlarm();
    super.dispose();
  }

  void _startTelemetry() {
    _telemetry.startTelemetry(
      widget.driver.id,
      driverName: widget.driver.displayName,
      vehicleLabel: widget.driver.vehicleLabel,
    );
  }

  void _setupRealtimeDispatchChannel() {
    final client = Supabase.instance.client;
    _subscription = client
        .channel('driver_dispatch_realtime_${widget.driver.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'emergency_requests',
          callback: (payload) {
            debugPrint('Realtime dispatch event: ${payload.eventType}');
            final record = payload.newRecord;
            final String? reqStatus = record['status']?.toString();
            final String? driverId = record['driver_id']?.toString();
            final String? recordId = record['id']?.toString();

            final bool isFinishedOrCancelled = reqStatus == 'Completed' ||
                reqStatus == 'completed' ||
                reqStatus == 'Cancelled / failed' ||
                reqStatus == 'cancelled' ||
                reqStatus == 'Declined' ||
                reqStatus == 'aborted';

            // 1. If currently active mission was cancelled or completed, IMMEDIATELY CLEAR IT
            if (_activeMission?.id == recordId && isFinishedOrCancelled) {
              if (mounted) {
                setState(() {
                  _activeMission = null;
                });
              }
              _telemetry.setActiveMissionState(null);
              if (reqStatus?.toLowerCase().contains('cancel') == true) {
                _triggerAlarm('⚠️ MISSION CANCELLED: Dispatcher has cancelled this emergency run.');
              }
              _fetchJobHistory();
              _fetchActiveMission(silent: true);
              _fetchAvailableJobs(silent: true);
              return;
            }

            // 2. If this is an assigned mission for this driver
            if (driverId != null && driverId == widget.driver.id) {
              if (isFinishedOrCancelled) {
                if (mounted) {
                  setState(() => _activeMission = null);
                }
                _telemetry.setActiveMissionState(null);
                _fetchJobHistory();
                return;
              }

              final bool isNewAssignment = _activeMission == null || _activeMission!.id != recordId;

              // Active run assigned to this driver
              try {
                final fastModel = EmergencyRequestModel.fromJson(Map<String, dynamic>.from(record));
                if (mounted) {
                  setState(() {
                    _activeMission = fastModel;
                    _currentTabIndex = 0; // Focus on active mission
                  });
                }
                _telemetry.setActiveMissionState(fastModel.id);
              } catch (parseErr) {
                debugPrint('Fast parse error from WebSocket: $parseErr');
              }

              _fetchActiveMission(silent: true);
              if (isNewAssignment) {
                _triggerAlarm(
                  '🚨 DISPATCH: You have been assigned an emergency run!',
                  requestId: recordId,
                  address: record['patient_address']?.toString(),
                  type: record['emergency_type']?.toString(),
                );
              }
            } else if (_activeMission?.id == recordId && driverId != widget.driver.id) {
              // Reassigned away to another driver
              if (mounted) {
                setState(() => _activeMission = null);
              }
              _telemetry.setActiveMissionState(null);
              _fetchActiveMission(silent: true);
            } else if (reqStatus == 'pending' || reqStatus == 'broadcasted' || reqStatus == 'Pending' || reqStatus == 'Requested' || reqStatus == 'Matching') {
              _fetchAvailableJobs(silent: true);
              if (!_isAudioMuted) {
                _triggerAlarm('🚨 NEW EMERGENCY BROADCAST! Tap Available Jobs to view.');
              }
            } else {
              _fetchActiveMission(silent: true);
              _fetchAvailableJobs(silent: true);
            }
          },
        )
        .onBroadcast(
          event: 'emergency_assigned',
          callback: (payload) {
            debugPrint('Direct broadcast emergency_assigned received: $payload');
            _fetchActiveMission(silent: true);
            _triggerAlarm(
              '🚨 DISPATCH: New emergency assigned by dispatcher!',
              requestId: payload['request_id']?.toString(),
              address: payload['patient_address']?.toString(),
              type: payload['emergency_type']?.toString(),
            );
          },
        )
        .onBroadcast(
          event: 'tactical_alert_ack',
          callback: (payload) {
            debugPrint('Dispatcher tactical_alert_ack received: $payload');
            _fetchActiveMission(silent: true);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('📻 DISPATCH ACKNOWLEDGED: ${payload['response'] ?? "Understood"}'),
                  backgroundColor: const Color(0xFF10B981),
                  duration: const Duration(seconds: 4),
                ),
              );
            }
          },
        )
        .subscribe();
  }

  void _triggerAlarm(String message, {String? requestId, String? address, String? type}) {
    HapticFeedback.heavyImpact();
    if (!_isAudioMuted) {
      _audio.playDispatchAlarm();
    }
    _fcm.showEmergencyDispatchAlert(
      title: '🚨 EMERGENCY DISPATCH ASSIGNED!',
      body: address != null && address.isNotEmpty
          ? '${type ?? "Emergency Run"}: $address. Respond immediately.'
          : message,
      payload: requestId,
    );
    if (mounted) {
      setState(() {
        _incomingAlertMessage = message;
      });
    }
  }

  void _dismissAlarm() {
    _audio.stopAlarm();
    if (mounted) {
      setState(() {
        _incomingAlertMessage = null;
      });
    }
  }

  Future<void> _fetchActiveMission({bool silent = false}) async {
    if (!silent) setState(() => _isLoadingActive = true);
    _activeFetchError = null;

    dynamic activeRecord;

    bool rpcSucceeded = false;
    // Strategy 1: Call RPC
    try {
      final rpcRes = await Supabase.instance.client.rpc('get_driver_active_mission', params: {
        'p_driver_id': widget.driver.id,
      });
      rpcSucceeded = true;
      if (rpcRes != null) {
        activeRecord = rpcRes;
      }
    } catch (rpcErr) {
      debugPrint('RPC get_driver_active_mission notice: $rpcErr');
    }

    // Strategy 2: Fallback to direct query ONLY if RPC itself threw an error
    if (!rpcSucceeded && activeRecord == null) {
      try {
        final queryRes = await Supabase.instance.client
            .from('emergency_requests')
            .select('*, hospitals:hospitals(*)')
            .eq('driver_id', widget.driver.id)
            .not('status', 'in', '("Completed","Cancelled / failed","cancelled","completed")')
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle();

        if (queryRes != null) {
          activeRecord = queryRes;
        }
      } catch (queryErr) {
        debugPrint('Direct query emergency_requests notice: $queryErr');
        _activeFetchError = queryErr.toString();
      }
    }

    if (mounted) {
      final previousMissionId = _activeMission?.id;
      setState(() {
        if (activeRecord != null) {
          final newMission = EmergencyRequestModel.fromJson(Map<String, dynamic>.from(activeRecord as Map));
          _activeMission = newMission;
          _activeFetchError = null;
          _telemetry.setActiveMissionState(newMission.id);

          // If a new emergency has been assigned, trigger siren and notification immediately!
          if (previousMissionId != newMission.id) {
            _currentTabIndex = 0;
            _triggerAlarm(
              '🚨 DISPATCH: Emergency assigned to your unit!',
              requestId: newMission.id,
              address: newMission.patientAddress,
              type: newMission.emergencyType,
            );
          }
        } else {
          // If no active run exists in database, cleanly clear mission from screen
          _activeMission = null;
          _activeFetchError = null;
          _telemetry.setActiveMissionState(null);
        }
        _isLoadingActive = false;
      });
    }
  }

  Future<void> _fetchAvailableJobs({bool silent = false}) async {
    if (!silent) setState(() => _isLoadingAvailable = true);
    _availableFetchError = null;

    List<dynamic> listData = [];
    bool rpcSucceeded = false;

    try {
      final res = await Supabase.instance.client.rpc('get_available_emergency_jobs');
      rpcSucceeded = true;
      if (res is List && res.isNotEmpty) {
        listData = res;
      }
    } catch (rpcErr) {
      debugPrint('RPC get_available_emergency_jobs notice: $rpcErr');
    }

    if (!rpcSucceeded && listData.isEmpty) {
      try {
        final queryRes = await Supabase.instance.client
            .from('emergency_requests')
            .select('*, hospitals:hospitals(*)')
            .isFilter('driver_id', null)
            .not('status', 'in', '("Completed","Cancelled / failed","cancelled","completed")')
            .order('created_at', ascending: false)
            .limit(20);

        if (queryRes is List && queryRes.isNotEmpty) {
          listData = queryRes;
        }
      } catch (queryErr) {
        debugPrint('Direct query available jobs notice: $queryErr');
        _availableFetchError = queryErr.toString();
      }
    }

    if (mounted) {
      setState(() {
        _availableJobs = listData
            .map((item) => EmergencyRequestModel.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList();
        _isLoadingAvailable = false;
      });
    }
  }

  Future<void> _fetchJobHistory() async {
    setState(() => _isLoadingHistory = true);
    try {
      dynamic res;
      final driverId = widget.driver.id;
      final userId = widget.driver.userId;

      // Strategy 1: Joined query with hospitals
      try {
        if (userId != null && userId.isNotEmpty && userId != driverId) {
          res = await Supabase.instance.client
              .from('emergency_requests')
              .select('*, hospitals(*)')
              .or('driver_id.eq.$driverId,driver_id.eq.$userId')
              .order('created_at', ascending: false)
              .limit(50);
        } else {
          res = await Supabase.instance.client
              .from('emergency_requests')
              .select('*, hospitals(*)')
              .eq('driver_id', driverId)
              .order('created_at', ascending: false)
              .limit(50);
        }
      } catch (e1) {
        debugPrint('Joined history query note: $e1');
        // Strategy 2: Plain select without relationship join
        try {
          if (userId != null && userId.isNotEmpty && userId != driverId) {
            res = await Supabase.instance.client
                .from('emergency_requests')
                .select('*')
                .or('driver_id.eq.$driverId,driver_id.eq.$userId')
                .order('created_at', ascending: false)
                .limit(50);
          } else {
            res = await Supabase.instance.client
                .from('emergency_requests')
                .select('*')
                .eq('driver_id', driverId)
                .order('created_at', ascending: false)
                .limit(50);
          }
        } catch (e2) {
          debugPrint('Plain history query note: $e2');
          res = await Supabase.instance.client
              .from('emergency_requests')
              .select('*')
              .eq('driver_id', driverId)
              .order('created_at', ascending: false)
              .limit(50);
        }
      }

      if (mounted) {
        final List<EmergencyRequestModel> items = [];
        for (final item in (res as List)) {
          final model = EmergencyRequestModel.fromJson(Map<String, dynamic>.from(item as Map));
          final st = model.status.toLowerCase().trim();
          final isCurrentlyActive = st == 'driver assigned' ||
              st == 'en route to patient' ||
              st == 'patient picked up' ||
              st == 'en route to hospital' ||
              st == 'matching' ||
              st == 'requested';

          if (!isCurrentlyActive) {
            items.add(model);
          }
        }

        setState(() {
          _jobHistory = items;
          _isLoadingHistory = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching job history: $e');
      if (mounted) setState(() => _isLoadingHistory = false);
    }
  }

  void _onMissionAccepted(EmergencyRequestModel acceptedMission) {
    setState(() {
      _activeMission = acceptedMission;
      _currentTabIndex = 0; // Instantly navigate to Active Mission tab
    });
    _telemetry.setActiveMissionState(acceptedMission.id);
    _fetchActiveMission();
    _fetchAvailableJobs(silent: true);
  }

  Future<void> _signOut() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('End Shift & Sign Out', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Text(
          _activeMission != null
              ? 'WARNING: You have an ACTIVE MISSION in progress. You should complete the emergency run or notify Dispatch before ending your shift.'
              : 'Are you sure you want to end your shift? Your GPS telemetry will stop transmitting.',
          style: const TextStyle(color: Color(0xFF94A3B8)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Confirm Sign Out'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    await _telemetry.stopTelemetry(setOffDuty: true);
    await Supabase.instance.client.auth.signOut();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const DriverLoginScreen()),
      );
    }
  }

  /// EMERGENCY DISTRESS SOS TRIGGER
  Future<void> _showEmergencySosDialog() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.crisis_alert_rounded, color: Colors.redAccent, size: 28),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'EMERGENCY SOS TRIGGER',
                style: TextStyle(color: Colors.redAccent, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Text(
          'Transmit immediate EMERGENCY DISTRESS SIGNAL to Dispatch Desk & Admin Console for unit ${widget.driver.vehicleLabel ?? widget.driver.displayName}?\n\nThis immediately alerts dispatchers with high-priority audio alarm.',
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            child: const Text('🚨 TRANSMIT SOS ALARM', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      HapticFeedback.heavyImpact();
      final targetReqId = _activeMission?.id;
      final now = DateTime.now();

      // 1. If active mission, trigger RPC trigger_driver_emergency_alert
      if (targetReqId != null) {
        try {
          await Supabase.instance.client.rpc('trigger_driver_emergency_alert', params: {
            'p_request_id': targetReqId,
            'p_alert_code': 'SOS',
            'p_alert_message': '🚨 EMERGENCY SOS DISTRESS SIGNAL: Ambulance crew in distress!',
          });
        } catch (_) {}
      }

      // 2. Direct Realtime Broadcast to Dispatch Console
      try {
        final broadcastChannel = Supabase.instance.client.channel('ops-request-board-sync');
        await broadcastChannel.subscribe();
        await broadcastChannel.send(
          type: RealtimeListenTypes.broadcast,
          event: 'driver_tactical_alert',
          payload: {
            'request_id': targetReqId,
            'driver_id': widget.driver.id,
            'driver_name': widget.driver.displayName,
            'vehicle_label': widget.driver.vehicleLabel,
            'alert_code': 'SOS',
            'alert_message': '🚨 EMERGENCY SOS DISTRESS: Unit ${widget.driver.vehicleLabel ?? widget.driver.displayName} triggered emergency distress signal!',
            'created_at': now.toIso8601String(),
          },
        );
      } catch (_) {}

      // 3. Fallback direct update to notes if active mission
      if (targetReqId != null) {
        try {
          final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
          final existingNotes = _activeMission!.notes ?? '';
          await Supabase.instance.client.from('emergency_requests').update({
            'notes': '$existingNotes\n[TACTICAL ALERT $timeStr]: 🚨 EMERGENCY SOS DISTRESS SIGNAL TRANSMITTED',
          }).eq('id', targetReqId);
        } catch (_) {}
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.crisis_alert_rounded, color: Colors.amberAccent, size: 22),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'EMERGENCY SOS TRANSMITTED! Dispatch Desk notified.',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            backgroundColor: Color(0xFF991B1B),
            duration: Duration(seconds: 5),
          ),
        );
      }
    } catch (err) {
      debugPrint('Error triggering SOS: $err');
    }
  }

  /// SECURITY-GUARDED DUTY STATUS TOGGLE
  Future<void> _handleDutyToggle() async {
    // 1. Strict Security Guard: Cannot go off-duty while mission is active!
    if (_activeMission != null || !_telemetry.canGoOffDuty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.shield_rounded, color: Colors.amberAccent, size: 26),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Action Denied: Active Run',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: const Text(
            'Operational Security Policy: You cannot go Off-Duty or pause location tracking while actively assigned to an emergency mission.\n\nComplete the current run or coordinate with Dispatch to reassign before changing your duty status.',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13, height: 1.4),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0F172A),
                foregroundColor: Colors.white,
              ),
              child: const Text('Understood'),
            ),
          ],
        ),
      );
      return;
    }

    final wasOnDuty = _telemetry.isOnDuty;

    // 2. Prompt confirmation when going off duty
    if (wasOnDuty) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Confirm Off-Duty Status', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          content: const Text(
            'Switching to Off-Duty will pause live GPS telemetry and signal Dispatch that your unit is off-shift and unavailable for emergency calls.',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Stay On Duty', style: TextStyle(color: Colors.white60)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF59E0B)),
              child: const Text('Go Off-Duty'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    await _telemetry.toggleDuty(
      widget.driver.id,
      driverName: widget.driver.displayName,
      vehicleLabel: widget.driver.vehicleLabel,
    );
  }

  /// DEDICATED TACTICAL COMMAND BAR (Fixes UI clash completely)
  Widget _buildTacticalCommandBar() {
    final hasMission = _activeMission != null || _telemetry.hasActiveMission;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        border: Border(
          bottom: BorderSide(color: Color(0xFF334155), width: 1),
        ),
      ),
      child: Row(
        children: [
          // Left: Telemetry & Beacon indicator
          Expanded(
            child: ValueListenableBuilder<String>(
              valueListenable: _telemetry.statusNotifier,
              builder: (_, status, __) {
                final isTransmitting = status.contains('Transmitting');
                return Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: hasMission
                            ? const Color(0xFFEF4444)
                            : (isTransmitting ? const Color(0xFF34D399) : Colors.amberAccent),
                        shape: BoxShape.circle,
                        boxShadow: [
                          if (isTransmitting || hasMission)
                            BoxShadow(
                              color: (hasMission ? Colors.redAccent : const Color(0xFF34D399)).withOpacity(0.6),
                              blurRadius: 6,
                              spreadRadius: 1,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            hasMission
                                ? 'ACTIVE MISSION GPS'
                                : (isTransmitting ? 'TELEMETRY ONLINE' : 'TELEMETRY PAUSED'),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.6,
                              color: hasMission
                                  ? Colors.redAccent
                                  : (isTransmitting ? const Color(0xFF34D399) : Colors.white60),
                            ),
                          ),
                          Text(
                            hasMission
                                ? 'Location locked to Dispatcher'
                                : (isTransmitting ? 'Continuous high-accuracy GPS' : 'Unit standby (Off Duty)'),
                            style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),

          const SizedBox(width: 10),

          // Right: On Duty / Off Duty Quick Toggle (Glove-Friendly)
          ValueListenableBuilder<bool>(
            valueListenable: _telemetry.isOnDutyNotifier,
            builder: (_, isOnDuty, __) {
              if (hasMission) {
                return InkWell(
                  onTap: _handleDutyToggle,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.red.shade900.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.redAccent, width: 1.5),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lock_rounded, size: 13, color: Colors.redAccent),
                        SizedBox(width: 4),
                        Text(
                          'ON DUTY (LOCKED)',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            color: Colors.redAccent,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return InkWell(
                onTap: _handleDutyToggle,
                borderRadius: BorderRadius.circular(8),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: isOnDuty ? const Color(0xFF10B981).withOpacity(0.18) : const Color(0xFF334155),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isOnDuty ? const Color(0xFF10B981) : Colors.white38,
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: isOnDuty ? const Color(0xFF34D399) : Colors.white54,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isOnDuty ? 'ON DUTY' : 'OFF DUTY',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          color: isOnDuty ? const Color(0xFF34D399) : Colors.white70,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        leading: const Padding(
          padding: EdgeInsets.only(left: 12.0),
          child: Icon(Icons.local_hospital_rounded, color: Colors.redAccent, size: 24),
        ),
        leadingWidth: 36,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.driver.displayName,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '${widget.driver.vehicleLabel ?? "Ambulance Unit"} • ${widget.driver.phone ?? ""}',
              style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          // Audio Siren Alert Mute Toggle
          IconButton(
            icon: Icon(
              _isAudioMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              color: _isAudioMuted ? Colors.white38 : Colors.redAccent,
            ),
            tooltip: _isAudioMuted ? 'Unmute siren alert' : 'Mute siren alert',
            onPressed: () {
              setState(() {
                _isAudioMuted = !_isAudioMuted;
                if (_isAudioMuted) _audio.stopAlarm();
              });
            },
          ),
          // End Shift / Sign Out
          IconButton(
            icon: const Icon(Icons.logout_rounded, color: Colors.white70),
            tooltip: 'End Shift / Sign Out',
            onPressed: _signOut,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Dedicated Tactical Status & On-Duty Control Bar (Never overlaps)
            _buildTacticalCommandBar(),

            // Prominent Off-Duty Persistent Status Warning (when driver is off shift)
            ValueListenableBuilder<bool>(
              valueListenable: _telemetry.isOnDutyNotifier,
              builder: (_, isOnDuty, __) {
                if (isOnDuty || _activeMission != null) return const SizedBox.shrink();
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  color: const Color(0xFF334155),
                  child: Row(
                    children: [
                      const Icon(Icons.pause_circle_outline_rounded, color: Colors.amberAccent, size: 22),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Unit is OFF DUTY • Telemetry paused. You will not receive emergency dispatch calls.',
                          style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          _telemetry.startTelemetry(
                            widget.driver.id,
                            driverName: widget.driver.displayName,
                            vehicleLabel: widget.driver.vehicleLabel,
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          minimumSize: Size.zero,
                        ),
                        child: const Text('Go On Duty', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                );
              },
            ),

            // Live Audible Siren Banner (if dispatch triggered)
            if (_incomingAlertMessage != null)
              Material(
                color: Colors.red.shade900,
                child: InkWell(
                  onTap: () {
                    _dismissAlarm();
                    setState(() => _currentTabIndex = 0);
                    _fetchActiveMission(silent: false);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.crisis_alert_rounded, color: Colors.white, size: 24),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _incomingAlertMessage!,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                              const SizedBox(height: 2),
                              const Text(
                                'Tap here to open Active Mission console →',
                                style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: _dismissAlarm,
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Tab Content
            Expanded(
              child: IndexedStack(
                index: _currentTabIndex,
                children: [
                  // Tab 0: Active Mission
                  ActiveJobTab(
                    driver: widget.driver,
                    activeMission: _activeMission,
                    isLoading: _isLoadingActive,
                    errorMessage: _activeFetchError,
                    onRefresh: () => _fetchActiveMission(),
                    onGoToAvailableJobs: () {
                      setState(() => _currentTabIndex = 1);
                      _fetchAvailableJobs();
                    },
                  ),

                  // Tab 1: Available Jobs
                  AvailableJobsTab(
                    availableJobs: _availableJobs,
                    isLoading: _isLoadingAvailable,
                    errorMessage: _availableFetchError,
                    currentDriverId: widget.driver.id,
                    onRefresh: () => _fetchAvailableJobs(),
                    onMissionAccepted: _onMissionAccepted,
                  ),

                  // Tab 2: Job History
                  JobHistoryTab(
                    history: _jobHistory,
                    isLoading: _isLoadingHistory,
                    onRefresh: () => _fetchJobHistory(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTabIndex,
        backgroundColor: const Color(0xFF1E293B),
        indicatorColor: Colors.redAccent.withOpacity(0.2),
        onDestinationSelected: (idx) {
          setState(() => _currentTabIndex = idx);
          if (idx == 0) _fetchActiveMission();
          if (idx == 1) _fetchAvailableJobs();
          if (idx == 2) _fetchJobHistory();
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.navigation_outlined, color: Colors.white60),
            selectedIcon: const Icon(Icons.navigation_rounded, color: Colors.redAccent),
            label: _activeMission != null ? 'Active Mission 🚨' : 'Active Mission',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _availableJobs.isNotEmpty,
              label: Text('${_availableJobs.length}'),
              child: const Icon(Icons.list_alt_rounded, color: Colors.white60),
            ),
            selectedIcon: Badge(
              isLabelVisible: _availableJobs.isNotEmpty,
              label: Text('${_availableJobs.length}'),
              child: const Icon(Icons.list_alt_rounded, color: Colors.redAccent),
            ),
            label: 'Available Jobs',
          ),
          const NavigationDestination(
            icon: Icon(Icons.history_rounded, color: Colors.white60),
            selectedIcon: Icon(Icons.history_rounded, color: Colors.redAccent),
            label: 'Job History',
          ),
        ],
      ),
    );
  }
}
