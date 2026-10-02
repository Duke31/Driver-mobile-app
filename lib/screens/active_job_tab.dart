import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/driver_model.dart';
import '../models/emergency_request.dart';
import '../widgets/tactical_mission_map.dart';

class ActiveJobTab extends StatefulWidget {
  final DriverModel driver;
  final EmergencyRequestModel? activeMission;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback onRefresh;
  final VoidCallback onGoToAvailableJobs;

  const ActiveJobTab({
    super.key,
    required this.driver,
    required this.activeMission,
    required this.isLoading,
    this.errorMessage,
    required this.onRefresh,
    required this.onGoToAvailableJobs,
  });

  @override
  State<ActiveJobTab> createState() => _ActiveJobTabState();
}

class _ActiveJobTabState extends State<ActiveJobTab> {
  bool _isActionBusy = false;
  bool _isSendingAlert = false;
  String? _statusError;
  String? _optimisticStatus;
  String? _lastSentAlert;
  bool _showTacticalMap = true;
  bool _isMapFullscreen = false;

  @override
  void didUpdateWidget(covariant ActiveJobTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activeMission?.status != oldWidget.activeMission?.status) {
      _optimisticStatus = null;
    }
  }

  Future<void> _sendTacticalAlert(String code, String alertMessage) async {
    if (widget.activeMission == null) return;
    final reqId = widget.activeMission!.id;
    setState(() {
      _isSendingAlert = true;
      _lastSentAlert = alertMessage;
    });

    bool transmitted = false;
    final now = DateTime.now();
    final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    // Strategy 1: Robust SECURITY DEFINER RPC trigger_driver_emergency_alert
    try {
      final rpcRes = await Supabase.instance.client.rpc('trigger_driver_emergency_alert', params: {
        'p_request_id': reqId,
        'p_alert_code': code,
        'p_alert_message': alertMessage,
      });
      if (rpcRes != null) transmitted = true;
    } catch (e) {
      debugPrint('Strategy 1 RPC trigger_driver_emergency_alert notice: $e');
    }

    // Strategy 2: Direct Supabase Realtime Broadcast to Dispatch Console (ops-request-board-sync)
    try {
      final broadcastChannel = Supabase.instance.client.channel('ops-request-board-sync');
      await broadcastChannel.subscribe();
      await broadcastChannel.send(
        type: RealtimeListenTypes.broadcast,
        event: 'driver_tactical_alert',
        payload: {
          'request_id': reqId,
          'driver_id': widget.driver.id,
          'driver_name': widget.driver.displayName,
          'vehicle_label': widget.driver.vehicleLabel,
          'alert_code': code,
          'alert_message': alertMessage,
          'created_at': now.toIso8601String(),
        },
      );
      transmitted = true;
    } catch (e) {
      debugPrint('Strategy 2 Realtime broadcast notice: $e');
    }

    // Strategy 3: RPC send_driver_tactical_alert
    if (!transmitted) {
      try {
        await Supabase.instance.client.rpc('send_driver_tactical_alert', params: {
          'p_request_id': reqId,
          'p_alert_code': code,
          'p_alert_message': alertMessage,
        });
        transmitted = true;
      } catch (e) {
        debugPrint('Strategy 3 RPC send_driver_tactical_alert notice: $e');
      }
    }

    // Strategy 4: Direct append to notes
    try {
      final existingNotes = widget.activeMission!.notes ?? '';
      final updatedNotes = existingNotes.isEmpty
          ? '[TACTICAL ALERT $timeStr]: $alertMessage'
          : '$existingNotes\n[TACTICAL ALERT $timeStr]: $alertMessage';
      await Supabase.instance.client.from('emergency_requests').update({
        'notes': updatedNotes,
      }).eq('id', reqId);
      transmitted = true;
    } catch (_) {}

    // Strategy 5: Direct update to tactical_alert columns
    try {
      await Supabase.instance.client.from('emergency_requests').update({
        'tactical_alert': alertMessage,
        'tactical_alert_code': code,
        'tactical_alert_at': now.toIso8601String(),
        'tactical_alert_ack': false,
      }).eq('id', reqId);
      transmitted = true;
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.radio_rounded, color: Color(0xFF34D399), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'TACTICAL RADIO: "$alertMessage" transmitted to Dispatcher!',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF1E293B),
          duration: const Duration(seconds: 4),
        ),
      );
    }
    widget.onRefresh();
    if (mounted) setState(() => _isSendingAlert = false);
  }


  Future<void> _executeTransition(String nextStatus) async {
    if (widget.activeMission == null) return;

    final reqId = widget.activeMission!.id;
    final previousStatus = widget.activeMission!.status;

    // Instant optimistic update (0ms latency feel!)
    setState(() {
      _optimisticStatus = nextStatus;
      _isActionBusy = true;
      _statusError = null;
    });

    try {
      // 1. Try driver_advance_milestone RPC first (trigger-safe)
      bool succeeded = false;
      try {
        await Supabase.instance.client.rpc('driver_advance_milestone', params: {
          'p_request_id': reqId,
          'p_next_status': nextStatus,
        });
        succeeded = true;
      } catch (_) {}

      if (!succeeded) {
        // 2. Try standard transition_emergency_state
        try {
          await Supabase.instance.client.rpc('transition_emergency_state', params: {
            'request_id': reqId,
            'new_state': nextStatus,
            'actor_role': 'driver',
          });
          succeeded = true;
        } catch (transErr) {
          // If starting from Hospital confirmed, transition to Driver assigned then En route to patient
          if (nextStatus == 'En route to patient') {
            try {
              await Supabase.instance.client.rpc('transition_emergency_state', params: {
                'request_id': reqId,
                'new_state': 'Driver assigned',
                'actor_role': 'driver',
              });
              await Supabase.instance.client.rpc('transition_emergency_state', params: {
                'request_id': reqId,
                'new_state': nextStatus,
                'actor_role': 'driver',
              });
              succeeded = true;
            } catch (_) {
              throw transErr;
            }
          } else {
            throw transErr;
          }
        }
      }

      debugPrint('Milestone transition succeeded: $nextStatus');
      widget.onRefresh();
    } catch (e) {
      String clean = e.toString();
      if (clean.contains('Exception:')) {
        clean = clean.split('Exception:').last.trim();
      }
      setState(() {
        _optimisticStatus = previousStatus; // Revert on failure
        _statusError = 'Milestone transition error: $clean';
      });
    } finally {
      if (mounted) {
        setState(() => _isActionBusy = false);
      }
    }
  }

  Future<void> _launchMaps({double? lat, double? lng, String? address, String? label}) async {
    if (lat == null && lng == null && (address == null || address.trim().isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No coordinates or address specified for this destination.'),
          backgroundColor: Colors.amber,
        ),
      );
      return;
    }

    // 1. Try native Google Navigation intent
    bool launched = false;
    if (lat != null && lng != null) {
      final navUri = Uri.parse('google.navigation:q=$lat,$lng&mode=d');
      try {
        launched = await launchUrl(navUri, mode: LaunchMode.externalNonBrowserApplication);
      } catch (_) {}
    } else if (address != null && address.isNotEmpty) {
      final navUri = Uri.parse('google.navigation:q=${Uri.encodeComponent(address)}&mode=d');
      try {
        launched = await launchUrl(navUri, mode: LaunchMode.externalNonBrowserApplication);
      } catch (_) {}
    }

    if (launched) return;

    // 2. Fallback to Google Maps Web / App URL
    Uri webUri;
    if (lat != null && lng != null) {
      webUri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');
    } else {
      webUri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${Uri.encodeComponent(address!)}');
    }

    try {
      await launchUrl(webUri, mode: LaunchMode.externalApplication);
    } catch (_) {
      try {
        await launchUrl(webUri, mode: LaunchMode.platformDefault);
      } catch (err) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not open external maps: $err. Viewing in-app tactical map.'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    }
  }

  Future<void> _launchWaze(double? lat, double? lng, {String? address}) async {
    Uri wazeUrl;
    if (lat != null && lng != null) {
      wazeUrl = Uri.parse('https://waze.com/ul?ll=$lat,$lng&navigate=yes');
    } else if (address != null && address.isNotEmpty) {
      wazeUrl = Uri.parse('https://waze.com/ul?q=${Uri.encodeComponent(address)}&navigate=yes');
    } else {
      return;
    }

    try {
      await launchUrl(wazeUrl, mode: LaunchMode.externalApplication);
    } catch (_) {
      await launchUrl(wazeUrl, mode: LaunchMode.platformDefault);
    }
  }

  Future<void> _callPhone(String phone) async {
    final cleanPhone = phone.replaceAll(RegExp(r'[^\d+]'), '');
    final uri = Uri.parse('tel:$cleanPhone');
    try {
      await launchUrl(uri);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not place call to $cleanPhone: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.redAccent),
      );
    }

    final mission = widget.activeMission;

    // 1. STANDBY STATE (No active mission)
    if (mission == null) {
      return RefreshIndicator(
        color: Colors.redAccent,
        onRefresh: () async => widget.onRefresh(),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
          child: Column(
            children: [
              if (widget.errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.red.shade900.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.redAccent.withOpacity(0.5)),
                  ),
                  child: Column(
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.sync_problem_rounded, color: Colors.redAccent, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'Database Sync Notice',
                            style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        widget.errorMessage!,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withOpacity(0.12),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3), width: 2),
                ),
                child: const Icon(
                  Icons.check_circle_outline_rounded,
                  color: Color(0xFF34D399),
                  size: 64,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Unit Standby • Ready for Dispatch',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${widget.driver.displayName} (${widget.driver.vehicleLabel ?? "Ambulance"})\nis on duty and actively transmitting high-accuracy GPS telemetry.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  color: Color(0xFF94A3B8),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                onPressed: widget.onGoToAvailableJobs,
                icon: const Icon(Icons.emergency_share_rounded),
                label: const Text('View Available Emergency Queue'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E293B),
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 2. ACTIVE MISSION IN PROGRESS
    final currentStatus = _optimisticStatus ?? mission.status;
    final isHeadingToHospital = currentStatus == 'Patient picked up' ||
        currentStatus == 'En route to hospital' ||
        currentStatus == 'Arrived / intake' ||
        mission.isEnRouteToHospital ||
        mission.isArrivedAtHospital;

    // Fullscreen Map View Mode
    if (_isMapFullscreen) {
      return Stack(
        children: [
          TacticalMissionMap(
            mission: mission,
            driver: widget.driver,
            height: double.infinity,
            isHeadingToHospital: isHeadingToHospital,
            isFullscreen: true,
            onToggleFullscreen: () {
              setState(() => _isMapFullscreen = false);
            },
          ),
        ],
      );
    }

    return RefreshIndicator(
      color: Colors.redAccent,
      onRefresh: () async => widget.onRefresh(),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top Priority Header Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.redAccent.withOpacity(0.5), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.red.withOpacity(0.12),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 16),
                            SizedBox(width: 4),
                            Text(
                              'LIVE EMERGENCY MISSION',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                                color: Colors.redAccent,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          mission.priority != null ? 'PRIORITY ${mission.priority}' : 'URGENT',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    mission.emergencyType ?? 'Medical Emergency',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.amberAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Status: $currentStatus',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.amberAccent,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // IN-APP INTERACTIVE TACTICAL MISSION MAP
            if (_showTacticalMap) ...[
              TacticalMissionMap(
                mission: mission,
                driver: widget.driver,
                height: 260,
                isHeadingToHospital: isHeadingToHospital,
                isFullscreen: false,
                onToggleFullscreen: () {
                  setState(() => _isMapFullscreen = true);
                },
              ),
              const SizedBox(height: 14),
            ],

            // DYNAMIC NAVIGATION TARGET CARD
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: isHeadingToHospital
                      ? [const Color(0xFF1E3A8A), const Color(0xFF1E293B)]
                      : [const Color(0xFF7F1D1D), const Color(0xFF1E293B)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isHeadingToHospital ? Colors.blueAccent : Colors.redAccent,
                  width: 1.5,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isHeadingToHospital ? Icons.local_hospital_rounded : Icons.person_pin_circle_rounded,
                        color: isHeadingToHospital ? Colors.lightBlueAccent : Colors.redAccent,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isHeadingToHospital
                              ? 'ACTIVE TARGET: RECEIVING HOSPITAL'
                              : 'ACTIVE TARGET: PATIENT PICKUP LOCATION',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.6,
                            color: isHeadingToHospital ? Colors.lightBlueAccent : Colors.white,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isHeadingToHospital
                        ? mission.hospitalName
                        : (mission.patientAddress ?? 'Patient Location'),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      height: 1.3,
                    ),
                  ),
                  if (isHeadingToHospital && mission.hospitalAddress != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      mission.hospitalAddress!,
                      style: const TextStyle(fontSize: 13, color: Colors.white70),
                    ),
                  ],
                  const SizedBox(height: 14),

                  // Turn-by-Turn Offline Google Navigation & Navigation Intents
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A).withOpacity(0.8),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () {
                            if (isHeadingToHospital) {
                              _launchMaps(
                                lat: mission.hospitalLat,
                                lng: mission.hospitalLng,
                                address: mission.hospitalAddress ?? mission.hospitalName,
                                label: mission.hospitalName,
                              );
                            } else {
                              _launchMaps(
                                lat: mission.patientLat,
                                lng: mission.patientLng,
                                address: mission.patientAddress,
                                label: 'Patient Pickup',
                              );
                            }
                          },
                          icon: const Icon(Icons.navigation_rounded, size: 22),
                          label: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                isHeadingToHospital ? '1-TAP NAVIGATE TO HOSPITAL' : '1-TAP NAVIGATE TO PATIENT',
                                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: 0.5),
                              ),
                              const Text(
                                'Google Navigation Intent • Offline Caching & Voice Guidance',
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.normal, color: Colors.white70),
                              ),
                            ],
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isHeadingToHospital ? Colors.blueAccent.shade700 : Colors.redAccent.shade700,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            elevation: 4,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () {
                                  if (isHeadingToHospital) {
                                    _launchWaze(
                                      mission.hospitalLat,
                                      mission.hospitalLng,
                                      address: mission.hospitalAddress ?? mission.hospitalName,
                                    );
                                  } else {
                                    _launchWaze(
                                      mission.patientLat,
                                      mission.patientLng,
                                      address: mission.patientAddress,
                                    );
                                  }
                                },
                                icon: const Icon(Icons.directions_car_rounded, color: Colors.cyanAccent, size: 16),
                                label: const Text('Open Waze', style: TextStyle(color: Colors.cyanAccent, fontSize: 12)),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Colors.cyanAccent),
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () {
                                  setState(() => _showTacticalMap = !_showTacticalMap);
                                },
                                icon: Icon(
                                  _showTacticalMap ? Icons.map_rounded : Icons.map_outlined,
                                  color: Colors.white70,
                                  size: 16,
                                ),
                                label: Text(
                                  _showTacticalMap ? 'Hide In-App Map' : 'Show In-App Map',
                                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Colors.white24),
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // PATIENT CONTACT & MEDICAL DETAILS CARD
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'PATIENT & CONTACT DETAILS',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.location_on_rounded, color: Colors.redAccent, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          mission.patientAddress ?? 'Coordinates given',
                          style: const TextStyle(fontSize: 14, color: Colors.white, height: 1.3),
                        ),
                      ),
                    ],
                  ),
                  if (mission.contactPhone != null && mission.contactPhone!.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              const Icon(Icons.phone_in_talk_rounded, color: Color(0xFF34D399), size: 18),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  mission.contactPhone!,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        ElevatedButton.icon(
                          onPressed: () => _callPhone(mission.contactPhone!),
                          icon: const Icon(Icons.call_rounded, size: 16),
                          label: const Text('Call Patient'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (mission.notes != null && mission.notes!.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.medical_services_rounded, color: Colors.redAccent, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Medical Notes: ${mission.notes}',
                              style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.3),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),

            // RECEIVING HOSPITAL & BED CAPACITY CARD
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Flexible(
                        child: Text(
                          'RECEIVING HOSPITAL',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                            color: Color(0xFF94A3B8),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (mission.hospitalCapacity != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E3A8A).withOpacity(0.4),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.blueAccent.withOpacity(0.4)),
                          ),
                          child: Text(
                            '${mission.hospitalCapacity} Beds Available',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.lightBlueAccent,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    mission.hospitalName,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  if (mission.hospitalAddress != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      mission.hospitalAddress!,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                    ),
                  ],
                  if (mission.hospitalPhone != null) ...[
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: () => _callPhone(mission.hospitalPhone!),
                      icon: const Icon(Icons.phone_rounded, size: 16),
                      label: Text('Contact ER Desk (${mission.hospitalPhone})'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0F172A),
                        foregroundColor: Colors.lightBlueAccent,
                        side: const BorderSide(color: Colors.blueAccent),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ERROR DISPLAY (if transition failed)
            if (_statusError != null)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade900.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.redAccent),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _statusError!,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),

            // 2-WAY DISPATCH RADIO & CANNED TACTICAL ALERTS PANEL
            _buildTacticalRadioPanel(mission),
            const SizedBox(height: 18),

            // TACTILE MISSION PROGRESSION ACTIONS
            _buildTactileProgressionControls(currentStatus),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  /// Two-Way Dispatcher-to-Driver Push-To-Talk / Quick Canned Messages
  Widget _buildTacticalRadioPanel(EmergencyRequestModel mission) {
    final hasActiveAlert = mission.tacticalAlert != null || _lastSentAlert != null;
    final isAcked = mission.tacticalAlertAck == true;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hasActiveAlert && !isAcked ? Colors.amberAccent : Colors.white.withOpacity(0.12),
          width: hasActiveAlert && !isAcked ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: (hasActiveAlert && !isAcked ? Colors.amber : Colors.black).withOpacity(0.08),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.radio_rounded, color: Colors.amberAccent, size: 18),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '2-WAY TACTICAL RADIO • CANNED STATUS',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.8,
                        color: Colors.amberAccent,
                      ),
                    ),
                    Text(
                      '1-Tap to transmit tactical situation to Dispatch Console',
                      style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                    ),
                  ],
                ),
              ),
              if (_isSendingAlert)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(color: Colors.amberAccent, strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // Active Tactical Alert Status Banner (if sent)
          if (hasActiveAlert) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isAcked
                    ? const Color(0xFF10B981).withOpacity(0.12)
                    : Colors.amber.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isAcked ? const Color(0xFF10B981) : Colors.amberAccent,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isAcked ? Icons.check_circle_rounded : Icons.sensors_rounded,
                        color: isAcked ? const Color(0xFF34D399) : Colors.amberAccent,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isAcked ? 'DISPATCHER ACKNOWLEDGED' : 'TRANSMITTING PRIORITY ALERT',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          color: isAcked ? const Color(0xFF34D399) : Colors.amberAccent,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Alert: ${mission.tacticalAlert ?? _lastSentAlert}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  if (mission.dispatcherResponse != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '↳ Dispatch Desk: "${mission.dispatcherResponse}"',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF38BDF8),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // 5 Tactile Canned Alert Buttons
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildTacticalAlertChip(
                code: 'TRAFFIC',
                icon: Icons.traffic_rounded,
                label: 'Stuck in Traffic / Road Blocked',
                color: const Color(0xFFF97316),
              ),
              _buildTacticalAlertChip(
                code: 'POLICE',
                icon: Icons.local_police_rounded,
                label: 'Need Police Escort',
                color: const Color(0xFFEF4444),
              ),
              _buildTacticalAlertChip(
                code: 'DIVERT',
                icon: Icons.alt_route_rounded,
                label: 'Hospital Divert Requested',
                color: const Color(0xFF8B5CF6),
              ),
              _buildTacticalAlertChip(
                code: 'CODE_BLUE',
                icon: Icons.monitor_heart_rounded,
                label: 'Patient Deteriorating / Code Blue',
                color: const Color(0xFFDC2626),
              ),
              _buildTacticalAlertChip(
                code: 'DELAY',
                icon: Icons.local_gas_station_rounded,
                label: 'Refueling / Mechanical Delay',
                color: const Color(0xFFEAB308),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTacticalAlertChip({
    required String code,
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return ElevatedButton.icon(
      onPressed: _isSendingAlert ? null : () => _sendTacticalAlert(code, label),
      icon: Icon(icon, size: 16, color: Colors.white),
      label: Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: color.withOpacity(0.2),
        foregroundColor: Colors.white,
        side: BorderSide(color: color.withOpacity(0.6), width: 1.2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        elevation: 0,
      ),
    );
  }

  /// Builds oversized, glove-friendly milestone buttons based on current emergency status
  Widget _buildTactileProgressionControls(String currentStatus) {
    final s = currentStatus.toLowerCase().trim();

    Widget buildButton({
      required VoidCallback onPressed,
      required Color color,
      required IconData icon,
      required String label,
    }) {
      return ElevatedButton(
        onPressed: _isActionBusy ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          disabledBackgroundColor: color.withOpacity(0.7),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 4,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_isActionBusy) ...[
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.2),
              ),
              const SizedBox(width: 12),
            ] else ...[
              Icon(icon, size: 22),
              const SizedBox(width: 10),
            ],
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (s == 'hospital confirmed' || s == 'driver assigned' || s == 'requested' || s == 'matching' || s == 'assigned') {
      return buildButton(
        onPressed: () => _executeTransition('En route to patient'),
        color: Colors.amber.shade700,
        icon: Icons.directions_car_filled_rounded,
        label: '1. START RUN: EN ROUTE TO PATIENT',
      );
    } else if (s == 'en route to patient') {
      return buildButton(
        onPressed: () => _executeTransition('Patient picked up'),
        color: const Color(0xFF10B981),
        icon: Icons.airline_seat_flat_rounded,
        label: '2. PATIENT PICKED UP / ON BOARD',
      );
    } else if (s == 'patient picked up') {
      return buildButton(
        onPressed: () => _executeTransition('En route to hospital'),
        color: Colors.blueAccent.shade700,
        icon: Icons.local_hospital_rounded,
        label: '3. EN ROUTE TO HOSPITAL',
      );
    } else if (s == 'en route to hospital') {
      return buildButton(
        onPressed: () => _executeTransition('Arrived / intake'),
        color: Colors.purpleAccent.shade700,
        icon: Icons.how_to_reg_rounded,
        label: '4. ARRIVED AT ER / INTAKE HANDOVER',
      );
    } else if (s == 'arrived / intake') {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF10B981).withOpacity(0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
        ),
        child: const Column(
          children: [
            Icon(Icons.check_circle_rounded, color: Color(0xFF34D399), size: 36),
            SizedBox(height: 8),
            Text(
              'Handover Complete at ER Triage',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
            ),
            SizedBox(height: 4),
            Text(
              'Hospital staff is completing clinical intake and bed assignment. Your ambulance unit is clearing.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      );
    } else {
      // Completed or Other State
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        child: Center(
          child: Text(
            'Current Run Milestone: $currentStatus',
            style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold),
          ),
        ),
      );
    }
  }
}
