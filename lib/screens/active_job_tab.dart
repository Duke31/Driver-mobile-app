import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/driver_model.dart';
import '../models/emergency_request.dart';

class ActiveJobTab extends StatefulWidget {
  final DriverModel driver;
  final EmergencyRequestModel? activeMission;
  final bool isLoading;
  final VoidCallback onRefresh;
  final VoidCallback onGoToAvailableJobs;

  const ActiveJobTab({
    super.key,
    required this.driver,
    required this.activeMission,
    required this.isLoading,
    required this.onRefresh,
    required this.onGoToAvailableJobs,
  });

  @override
  State<ActiveJobTab> createState() => _ActiveJobTabState();
}

class _ActiveJobTabState extends State<ActiveJobTab> {
  bool _isActionBusy = false;
  String? _statusError;

  Future<void> _executeTransition(String nextStatus) async {
    if (widget.activeMission == null) return;

    setState(() {
      _isActionBusy = true;
      _statusError = null;
    });

    try {
      final res = await Supabase.instance.client.rpc('transition_emergency_state', params: {
        'request_id': widget.activeMission!.id,
        'new_state': nextStatus,
        'actor_role': 'driver',
      });
      debugPrint('Transition success: $res');
      widget.onRefresh();
    } catch (e) {
      setState(() {
        _statusError = 'Milestone update failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _isActionBusy = false);
      }
    }
  }

  Future<void> _launchMaps(double lat, double lng, {String? label}) async {
    final googleMapsUrl = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');
    if (await canLaunchUrl(googleMapsUrl)) {
      await launchUrl(googleMapsUrl, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _launchWaze(double lat, double lng) async {
    final wazeUrl = Uri.parse('https://waze.com/ul?ll=$lat,$lng&navigate=yes');
    if (await canLaunchUrl(wazeUrl)) {
      await launchUrl(wazeUrl, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _callPhone(String phone) async {
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
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
          padding: const EdgeInsets.all(24.0),
          child: Column(
            children: [
              const SizedBox(height: 40),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.emerald.withOpacity(0.12),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.emerald.withOpacity(0.3), width: 2),
                ),
                child: const Icon(
                  Icons.check_circle_outline_rounded,
                  color: Colors.emeraldAccent,
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
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: widget.onRefresh,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Refresh Mission Status'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: const BorderSide(color: Colors.white24),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 2. ACTIVE MISSION CONSOLE
    final bool isHeadingToHospital = mission.isEnRouteToHospital;
    final bool isArrivedAtHospital = mission.isArrivedAtHospital;

    return RefreshIndicator(
      color: Colors.redAccent,
      onRefresh: () async => widget.onRefresh(),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16.0),
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
                    mainAxisAlignment: MainAxisAlignment.between,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
                        ),
                        child: const Row(
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
                  Text(
                    'Status: ${mission.status}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.amberAccent,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // DYNAMIC NAVIGATION TARGET SWITCH CARD
            // Switches target from Patient to Hospital automatically when en route to hospital!
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
                      Text(
                        isHeadingToHospital
                            ? 'ACTIVE NAVIGATION TARGET: RECEIVING HOSPITAL'
                            : 'ACTIVE NAVIGATION TARGET: PATIENT PICKUP LOCATION',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                          color: isHeadingToHospital ? Colors.lightBlueAccent : Colors.white,
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
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
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

                  // Navigation Action Buttons
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            if (isHeadingToHospital) {
                              if (mission.hospitalLat != null && mission.hospitalLng != null) {
                                _launchMaps(mission.hospitalLat!, mission.hospitalLng!, label: mission.hospitalName);
                              }
                            } else {
                              if (mission.patientLat != null && mission.patientLng != null) {
                                _launchMaps(mission.patientLat!, mission.patientLng!, label: 'Patient');
                              }
                            }
                          },
                          icon: const Icon(Icons.navigation_rounded, size: 18),
                          label: Text(
                            isHeadingToHospital ? 'Navigate to Hospital' : 'Navigate to Patient',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isHeadingToHospital ? Colors.blueAccent : Colors.redAccent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: () {
                          if (isHeadingToHospital) {
                            if (mission.hospitalLat != null && mission.hospitalLng != null) {
                              _launchWaze(mission.hospitalLat!, mission.hospitalLng!);
                            }
                          } else {
                            if (mission.patientLat != null && mission.patientLng != null) {
                              _launchWaze(mission.patientLat!, mission.patientLng!);
                            }
                          }
                        },
                        icon: const Icon(Icons.directions_car_rounded, color: Colors.cyanAccent),
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFF0F172A),
                          padding: const EdgeInsets.all(12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        tooltip: 'Open in Waze',
                      ),
                    ],
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
                    children: [
                      const Icon(Icons.location_on_outlined, color: Colors.redAccent, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          mission.patientAddress ?? 'Patient Address unavailable',
                          style: const TextStyle(fontSize: 14, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                  if (mission.contactPhone != null && mission.contactPhone!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Icon(Icons.phone_rounded, color: Colors.greenAccent, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            mission.contactPhone!,
                            style: const TextStyle(fontSize: 14, color: Colors.white, fontWeight: FontWeight.w600),
                          ),
                        ),
                        ElevatedButton.icon(
                          onPressed: () => _callPhone(mission.contactPhone!),
                          icon: const Icon(Icons.call, size: 16),
                          label: const Text('Call Patient'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green.shade700,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
                        color: Colors.red.shade900.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.medical_services_rounded, color: Colors.redAccent, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Medical Notes: ${mission.notes}',
                              style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.3),
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

            // RECEIVING HOSPITAL INFO + CALL BUTTON CARD
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.blueAccent.withOpacity(0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.between,
                    children: [
                      const Text(
                        'RECEIVING HOSPITAL DESTINATION',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                          color: Colors.lightBlueAccent,
                        ),
                      ),
                      if (mission.hospitalCapacity != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.blueAccent.withOpacity(0.4)),
                          ),
                          child: Text(
                            '${mission.hospitalCapacity} Beds Available',
                            style: const TextStyle(fontSize: 11, color: Colors.lightBlueAccent, fontWeight: FontWeight.bold),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    mission.hospitalName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  if (mission.hospitalAddress != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      mission.hospitalAddress!,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                    ),
                  ],
                  const SizedBox(height: 12),
                  // One-tap call hospital ER button
                  ElevatedButton.icon(
                    onPressed: mission.hospitalPhone != null
                        ? () => _callPhone(mission.hospitalPhone!)
                        : null,
                    icon: const Icon(Icons.phone_in_talk_rounded, size: 18),
                    label: Text(
                      mission.hospitalPhone != null
                          ? 'Call Hospital ER Desk (${mission.hospitalPhone})'
                          : 'Hospital Phone Not Listed',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E3A8A),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.white10,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // STATUS ERROR DISPLAY
            if (_statusError != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade900.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
                ),
                child: Text(
                  _statusError!,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              const SizedBox(height: 12),
            ],

            // MISSION PROGRESSION MILESTONES
            const Text(
              'MISSION PROGRESSION MILESTONES',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
                color: Color(0xFF94A3B8),
              ),
            ),
            const SizedBox(height: 8),

            // Step 1: Accept & En Route to Patient
            if (mission.status == 'Driver assigned' || mission.status == 'assigned')
              ElevatedButton.icon(
                onPressed: _isActionBusy ? null : () => _executeTransition('En route to patient'),
                icon: const Icon(Icons.directions_run_rounded),
                label: const Text('1. ACCEPT & EN ROUTE TO PATIENT'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),

            // Step 2: Patient Picked Up / At Scene
            if (mission.status == 'En route to patient')
              ElevatedButton.icon(
                onPressed: _isActionBusy ? null : () => _executeTransition('Patient picked up'),
                icon: const Icon(Icons.airline_seat_flat_rounded),
                label: const Text('2. ARRIVED AT SCENE & PATIENT LOADED'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo.shade600,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),

            // Step 3: En Route to Hospital (triggers dynamic navigation switch!)
            if (mission.status == 'Patient picked up')
              ElevatedButton.icon(
                onPressed: _isActionBusy ? null : () => _executeTransition('En route to hospital'),
                icon: const Icon(Icons.local_hospital_rounded),
                label: const Text('3. EN ROUTE TO HOSPITAL'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.purple.shade600,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),

            // Step 4: Arrived at Hospital / Hand Over
            if (mission.status == 'En route to hospital')
              ElevatedButton.icon(
                onPressed: _isActionBusy ? null : () => _executeTransition('Arrived / intake'),
                icon: const Icon(Icons.how_to_reg_rounded),
                label: const Text('4. ARRIVED AT HOSPITAL / HAND OVER'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal.shade600,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),

            // Step 5: Completed
            if (isArrivedAtHospital)
              ElevatedButton.icon(
                onPressed: _isActionBusy ? null : () => _executeTransition('Completed'),
                icon: const Icon(Icons.task_alt_rounded),
                label: const Text('5. COMPLETE MISSION & STAND BY'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.emerald.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
