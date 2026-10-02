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
    _setupRealtimeDispatchChannel();
  }

  @override
  void dispose() {
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
                _fetchJobHistory();
                return;
              }

              // Active run assigned to this driver
              try {
                final fastModel = EmergencyRequestModel.fromJson(Map<String, dynamic>.from(record));
                if (mounted) {
                  setState(() {
                    _activeMission = fastModel;
                    _currentTabIndex = 0; // Focus on active mission
                  });
                }
              } catch (parseErr) {
                debugPrint('Fast parse error from WebSocket: $parseErr');
              }

              _fetchActiveMission(silent: true);
              if (!_isAudioMuted && (payload.eventType == PostgresChangeEvent.insert || reqStatus == 'Driver assigned')) {
                _triggerAlarm('🚨 DISPATCH: You have been assigned an emergency run!');
              }
            } else if (_activeMission?.id == recordId && driverId != widget.driver.id) {
              // Reassigned away to another driver
              if (mounted) {
                setState(() => _activeMission = null);
              }
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
            .not('status', 'in', '("Completed","Cancelled / failed")')
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
      setState(() {
        if (activeRecord != null) {
          _activeMission = EmergencyRequestModel.fromJson(Map<String, dynamic>.from(activeRecord as Map));
          _activeFetchError = null;
        } else {
          // If no active run exists in database, cleanly clear mission from screen
          _activeMission = null;
          // Standby is a clean, normal state, not an error!
          _activeFetchError = null;
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

    // Strategy 1: Call RPC
    try {
      final res = await Supabase.instance.client.rpc('get_available_emergency_jobs');
      rpcSucceeded = true;
      if (res is List && res.isNotEmpty) {
        listData = res;
      }
    } catch (rpcErr) {
      debugPrint('RPC get_available_emergency_jobs notice: $rpcErr');
    }

    // Strategy 2: Fallback to direct query only if RPC failed and returned no data
    if (!rpcSucceeded && listData.isEmpty) {
      try {
        final queryRes = await Supabase.instance.client
            .from('emergency_requests')
            .select('*, hospitals:hospitals(*)')
            .isFilter('driver_id', null)
            .not('status', 'in', '("Completed","Cancelled / failed")')
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
      try {
        final list = listData
            .map((item) => EmergencyRequestModel.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList();
        setState(() {
          _availableJobs = list;
          _isLoadingAvailable = false;
          _availableFetchError = null;
        });
      } catch (parseErr) {
        debugPrint('Parse error in available jobs: $parseErr');
        setState(() {
          _isLoadingAvailable = false;
          _availableFetchError = 'Parse error: $parseErr';
        });
      }
    }
  }

  Future<void> _fetchJobHistory() async {
    setState(() => _isLoadingHistory = true);
    try {
      dynamic res;
      try {
        res = await Supabase.instance.client.rpc('get_driver_job_history', params: {
          'p_driver_id': widget.driver.id,
        });
      } catch (_) {
        res = await Supabase.instance.client
            .from('emergency_requests')
            .select('*, hospitals:hospitals(*)')
            .eq('driver_id', widget.driver.id)
            .inFilter('status', ['Completed', 'Cancelled / failed'])
            .order('created_at', ascending: false)
            .limit(30);
      }

      if (mounted) {
        final list = (res is List ? res : [])
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
          // Feature B: Prominent On-Duty / Off-Duty Quick Toggle
          ValueListenableBuilder<bool>(
            valueListenable: _telemetry.isOnDutyNotifier,
            builder: (_, isOnDuty, __) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 6.0),
                  child: InkWell(
                    onTap: () {
                      _telemetry.toggleDuty(
                        widget.driver.id,
                        driverName: widget.driver.displayName,
                        vehicleLabel: widget.driver.vehicleLabel,
                      );
                    },
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: isOnDuty ? const Color(0xFF10B981).withOpacity(0.18) : Colors.white12,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isOnDuty ? const Color(0xFF10B981) : Colors.white38,
                          width: 1.5,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: isOnDuty ? const Color(0xFF34D399) : Colors.white54,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            isOnDuty ? 'ON DUTY' : 'OFF DUTY',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.6,
                              color: isOnDuty ? const Color(0xFF34D399) : Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
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
            // Prominent Off-Duty Persistent Status Warning
            ValueListenableBuilder<bool>(
              valueListenable: _telemetry.isOnDutyNotifier,
              builder: (_, isOnDuty, __) {
                if (isOnDuty) return const SizedBox.shrink();
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
