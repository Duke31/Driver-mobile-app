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

  EmergencyRequestModel? _activeMission;
  List<EmergencyRequestModel> _availableJobs = [];
  List<EmergencyRequestModel> _jobHistory = [];

  bool _isLoadingActive = true;
  bool _isLoadingAvailable = true;
  bool _isLoadingHistory = false;

  bool _isAudioMuted = false;
  String? _incomingAlertMessage;
  RealtimeChannel? _subscription;

  @override
  void initState() {
    super.initState();
    _startTelemetry();
    _fetchActiveMission();
    _fetchAvailableJobs();
    _setupRealtimeDispatchChannel();
  }

  @override
  void dispose() {
    _subscription?.unsubscribe();
    _audio.stopAlarm();
    super.dispose();
  }

  void _startTelemetry() {
    _telemetry.startTelemetry(widget.driver.id);
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

            // Check if this is an assigned mission for this driver
            if (driverId == widget.driver.id) {
              _fetchActiveMission(silent: true);
              if (!_isAudioMuted && (payload.eventType == PostgresChangeEvent.insert || reqStatus == 'Driver assigned')) {
                _triggerAlarm('🚨 DISPATCH: You have been assigned an emergency run!');
              }
            } else if (reqStatus == 'pending' || reqStatus == 'broadcasted' || reqStatus == 'Pending') {
              // Open dispatch broadcasted to fleet
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
        .subscribe();
  }

  void _triggerAlarm(String message) {
    _audio.playDispatchAlarm();
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
    try {
      final res = await Supabase.instance.client.rpc('get_driver_active_mission', params: {
        'p_driver_id': widget.driver.id,
      });

      if (mounted) {
        setState(() {
          if (res != null) {
            _activeMission = EmergencyRequestModel.fromJson(Map<String, dynamic>.from(res as Map));
          } else {
            _activeMission = null;
          }
          _isLoadingActive = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching active mission: $e');
      if (mounted && !silent) setState(() => _isLoadingActive = false);
    }
  }

  Future<void> _fetchAvailableJobs({bool silent = false}) async {
    if (!silent) setState(() => _isLoadingAvailable = true);
    try {
      final res = await Supabase.instance.client.rpc('get_available_emergency_jobs');
      if (mounted) {
        final list = (res as List)
            .map((item) => EmergencyRequestModel.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList();
        setState(() {
          _availableJobs = list;
          _isLoadingAvailable = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching available jobs: $e');
      if (mounted && !silent) setState(() => _isLoadingAvailable = false);
    }
  }

  Future<void> _fetchJobHistory() async {
    setState(() => _isLoadingHistory = true);
    try {
      final res = await Supabase.instance.client.rpc('get_driver_job_history', params: {
        'p_driver_id': widget.driver.id,
      });
      if (mounted) {
        final list = (res as List)
            .map((item) => EmergencyRequestModel.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList();
        setState(() {
          _jobHistory = list;
          _isLoadingHistory = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching job history: $e');
      if (mounted) setState(() => _isLoadingHistory = false);
    }
  }

  void _onMissionAccepted(EmergencyRequestModel job) {
    _dismissAlarm();
    // Switch to Active Mission tab and reload
    setState(() {
      _currentTabIndex = 0;
    });
    _fetchActiveMission();
    _fetchAvailableJobs();
  }

  void _signOut() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('End Shift & Sign Out?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'This will terminate live GPS telemetry and return you to the driver sign-in screen.',
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
            child: const Text('Sign Out', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _telemetry.stopTelemetry();
      await Supabase.instance.client.auth.signOut();
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.emergency_rounded, color: Colors.redAccent, size: 20),
                const SizedBox(width: 8),
                Text(
                  widget.driver.displayName,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ],
            ),
            const SizedBox(height: 2),
            ValueListenableBuilder<String>(
              valueListenable: _telemetry.statusNotifier,
              builder: (_, status, __) {
                return Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: status.contains('Transmitting') ? const Color(0xFF34D399) : Colors.amberAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '${widget.driver.vehicleLabel ?? "Unit"} • $status',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
        actions: [
          // Audio Alert Mute Toggle
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
            // Live Audible Siren Banner (if dispatch triggered)
            if (_incomingAlertMessage != null)
              Container(
                color: Colors.red.shade900,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.crisis_alert_rounded, color: Colors.white, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _incomingAlertMessage!,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: _dismissAlarm,
                    ),
                  ],
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
