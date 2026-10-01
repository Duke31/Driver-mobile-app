import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import '../models/driver_model.dart';
import '../models/emergency_request.dart';
import '../services/telemetry_service.dart';
import '../services/audio_service.dart';
import 'driver_login_screen.dart';

class MissionScreen extends StatefulWidget {
  final DriverModel driver;

  const MissionScreen({super.key, required this.driver});

  @override
  State<MissionScreen> createState() => _MissionScreenState();
}

class _MissionScreenState extends State<MissionScreen> {
  final TelemetryService _telemetry = TelemetryService();
  final AudioAlarmService _audio = AudioAlarmService();

  EmergencyRequestModel? _activeMission;
  bool _isLoading = true;
  String? _statusError;
  bool _isActionBusy = false;

  RealtimeChannel? _subscription;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    // 1. Start continuous GPS & battery telemetry
    _telemetry.startTelemetry(widget.driver.id);

    // 2. Fetch current mission
    _fetchActiveMission();

    // 3. Set up real-time listener for incoming assignments
    _setupRealtimeSubscription();

    // 4. Polling fallback every 15 seconds
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _fetchActiveMission(silent: true);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _subscription?.unsubscribe();
    super.dispose();
  }

  void _setupRealtimeSubscription() {
    final client = Supabase.instance.client;
    _subscription = client
        .channel('driver_missions_${widget.driver.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'emergency_requests',
          callback: (payload) {
            final record = payload.newRecord;
            if (record['driver_id'] == widget.driver.id) {
              _fetchActiveMission();
              // Sound alert on new dispatch
              if (payload.eventType == PostgresChangeEvent.insert ||
                  record['status'] == 'assigned') {
                _audio.playDispatchAlarm();
              }
            }
          },
        )
        .subscribe();
  }

  Future<void> _fetchActiveMission({bool silent = false}) async {
    if (!silent) {
      setState(() => _isLoading = true);
    }

    try {
      final res = await Supabase.instance.client
          .from('emergency_requests')
          .select('*, hospitals(*)')
          .eq('driver_id', widget.driver.id)
          .not('status', 'in', '("completed","cancelled")')
          .order('created_at', ascending: false)
          .limit(1);

      final list = res as List;
      if (list.isNotEmpty) {
        final mission = EmergencyRequestModel.fromJson(list.first as Map<String, dynamic>);
        setState(() {
          _activeMission = mission;
          _isLoading = false;
        });
      } else {
        setState(() {
          _activeMission = null;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching mission: $e');
      if (!silent) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _updateMissionStatus(String newStatus) async {
    if (_activeMission == null) return;

    setState(() {
      _isActionBusy = true;
      _statusError = null;
    });

    try {
      // Transition state using RPC
      final rpcRes = await Supabase.instance.client.rpc('transition_emergency_state', params: {
        'request_id': _activeMission!.id,
        'new_state': newStatus,
        'actor_role': 'driver',
      });

      debugPrint('Transition result: $rpcRes');
      await _fetchActiveMission();
    } catch (e) {
      // Fallback: direct table update if permitted
      try {
        await Supabase.instance.client
            .from('emergency_requests')
            .update({'status': newStatus})
            .eq('id', _activeMission!.id);
        await _fetchActiveMission();
      } catch (directErr) {
        setState(() {
          _statusError = 'Status update failed: $directErr';
        });
      }
    } finally {
      setState(() {
        _isActionBusy = false;
      });
    }
  }

  Future<void> _launchMaps(double lat, double lng, {String? label}) async {
    final googleMapsUrl = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');
    if (await canLaunchUrl(googleMapsUrl)) {
      await launchUrl(googleMapsUrl, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _callPhone(String phone) async {
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  void _leaveDuty() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('End Shift & Go Off Duty?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'This will stop background GPS telemetry and mark this unit off-duty.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('End Shift', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _telemetry.stopTelemetry();
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const DriverLoginScreen()),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        title: Row(
          children: [
            const Icon(Icons.emergency, color: Colors.redAccent, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.driver.displayName,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'End Shift / Change Unit',
            icon: const Icon(Icons.power_settings_new, color: Colors.redAccent),
            onPressed: _leaveDuty,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // TELEMETRY HUD BAR (Screen Wake Lock, Battery, GPS)
            _buildTelemetryHUD(),

            // MAIN CONTENT (Active Mission or Standby)
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: Colors.redAccent))
                  : _activeMission == null
                      ? _buildStandbyView()
                      : _buildActiveMissionCard(_activeMission!),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTelemetryHUD() {
    return ValueListenableBuilder(
      valueListenable: _telemetry.positionNotifier,
      builder: (context, pos, _) {
        final speedKmh = pos != null && pos.speed > 0 ? (pos.speed * 3.6).round() : 0;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: const Color(0xFF161E2E),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // GPS Indicator
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: pos != null ? Colors.emerald : Colors.amber,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: (pos != null ? Colors.emerald : Colors.amber).withOpacity(0.5),
                          blurRadius: 6,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    pos != null ? 'GPS LOCKED' : 'SEARCHING GPS',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                      color: pos != null ? const Color(0xFF10B981) : Colors.amber,
                    ),
                  ),
                ],
              ),

              // Speed HUD
              Row(
                children: [
                  const Icon(Icons.speed, size: 16, color: Colors.white70),
                  const SizedBox(width: 4),
                  Text(
                    '$speedKmh km/h',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),

              // Battery & Wakelock
              Row(
                children: [
                  Icon(
                    _telemetry.isCharging ? Icons.battery_charging_full : Icons.battery_std,
                    size: 16,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '${_telemetry.batteryLevel}%',
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.screen_lock_rotation, size: 14, color: Colors.emerald),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStandbyView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.blueGrey.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.radio,
                size: 64,
                color: Color(0xFF38BDF8),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Awaiting Dispatch',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Unit is On Duty. Background GPS is streaming to dispatchers. Keep phone in cradle.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Colors.slate.shade400,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () => _fetchActiveMission(),
              icon: const Icon(Icons.sync, color: Colors.white70),
              label: const Text('Refresh Dispatch Board', style: TextStyle(color: Colors.white)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white24),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveMissionCard(EmergencyRequestModel mission) {
    final status = mission.status;
    final isEnRouteScene = status == 'assigned' || status == 'en_route_pickup' || status == 'en_route';
    final isAtScene = status == 'at_scene' || status == 'patient_onboard';
    final isEnRouteHospital = status == 'en_route_hospital';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // PRIORITY EMERGENCY BANNER
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.red.shade900.withOpacity(0.8),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.redAccent.withOpacity(0.5)),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (mission.emergencyType ?? 'MEDICAL EMERGENCY').toUpperCase(),
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: 0.5,
                        ),
                      ),
                      Text(
                        'Status: ${mission.status.replaceAll('_', ' ').toUpperCase()}',
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // PATIENT LOCATION & ADDRESS
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'PATIENT PICKUP SCENE',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.redAccent,
                        letterSpacing: 0.5,
                      ),
                    ),
                    if (mission.contactPhone != null && mission.contactPhone!.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.phone, color: Colors.emerald, size: 22),
                        onPressed: () => _callPhone(mission.contactPhone!),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  mission.patientAddress ?? 'Coordinates Provided (${mission.patientLat}, ${mission.patientLng})',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                if (mission.notes != null && mission.notes!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Clinical Notes: ${mission.notes}',
                      style: const TextStyle(fontSize: 13, color: Colors.white70),
                    ),
                  ),
                ],
                const SizedBox(height: 14),

                // ONE-TAP GOOGLE MAPS NAVIGATION TO PATIENT
                if (mission.patientLat != null && mission.patientLng != null)
                  ElevatedButton.icon(
                    onPressed: () => _launchMaps(mission.patientLat!, mission.patientLng!),
                    icon: const Icon(Icons.navigation, color: Colors.white),
                    label: const Text(
                      'NAVIGATE TO PATIENT (GOOGLE MAPS)',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // RECEIVING HOSPITAL
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'DESTINATION HOSPITAL',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF38BDF8),
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  mission.hospitalName,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                if (mission.hospitalAddress != null)
                  Text(
                    mission.hospitalAddress!,
                    style: const TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                if (mission.hospitalLat != null && mission.hospitalLng != null) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => _launchMaps(mission.hospitalLat!, mission.hospitalLng!),
                    icon: const Icon(Icons.local_hospital, color: Color(0xFF38BDF8)),
                    label: const Text(
                      'Navigate to Hospital',
                      style: TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF38BDF8)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),

          // TACTILE MISSION PROGRESSION BUTTONS (BIG FOR DRIVERS)
          if (_statusError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _statusError!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),

          if (_isActionBusy)
            const Center(child: CircularProgressIndicator(color: Colors.redAccent))
          else if (isEnRouteScene) ...[
            _buildLargeActionButton(
              title: 'ARRIVED AT SCENE',
              subtitle: 'Tap once ambulance arrives at caller location',
              color: const Color(0xFFF59E0B),
              icon: Icons.place,
              onTap: () => _updateMissionStatus('at_scene'),
            ),
          ] else if (isAtScene) ...[
            _buildLargeActionButton(
              title: 'PATIENT ONBOARD / EN ROUTE TO HOSPITAL',
              subtitle: 'Patient secured in ambulance, starting hospital transit',
              color: const Color(0xFF3B82F6),
              icon: Icons.airline_seat_flat,
              onTap: () => _updateMissionStatus('en_route_hospital'),
            ),
          ] else if (isEnRouteHospital) ...[
            _buildLargeActionButton(
              title: 'ARRIVED AT HOSPITAL & HANDED OVER',
              subtitle: 'Mission complete, patient in hospital care',
              color: const Color(0xFF10B981),
              icon: Icons.check_circle_outline,
              onTap: () => _updateMissionStatus('completed'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLargeActionButton({
    required String title,
    required String subtitle,
    required Color color,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(16),
      elevation: 4,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            children: [
              Icon(icon, color: Colors.white, size: 36),
              const SizedBox(height: 8),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
