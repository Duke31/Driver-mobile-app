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
  String? _statusError;
  bool _showTacticalMap = true;
  bool _isMapFullscreen = false;

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
    final currentStatus = mission.status;
    final isHeadingToHospital = mission.isEnRouteToHospital || mission.isArrivedAtHospital;

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

                  // Navigation Action Buttons (Glove-Friendly & Fluid)
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
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
                          icon: const Icon(Icons.navigation_rounded, size: 20),
                          label: Text(
                            isHeadingToHospital ? 'Navigate to Hospital' : 'Navigate to Patient',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
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
                        icon: const Icon(Icons.directions_car_rounded, color: Colors.cyanAccent),
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFF0F172A),
                          padding: const EdgeInsets.all(14),
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
                          'RECEIVING HOSPITAL DESTINATION',
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

            // TACTILE MISSION PROGRESSION ACTIONS
            _buildTactileProgressionControls(currentStatus),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  /// Builds oversized, glove-friendly milestone buttons based on current emergency status
  Widget _buildTactileProgressionControls(String currentStatus) {
    if (_isActionBusy) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(color: Colors.redAccent, strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text(
                'Transmitting Milestone Update to Dispatch...',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    if (currentStatus == 'Driver assigned') {
      return ElevatedButton(
        onPressed: () => _executeTransition('En route to patient'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.amber.shade700,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 4,
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.directions_car_filled_rounded, size: 24),
            SizedBox(width: 10),
            Text(
              'EN ROUTE TO PATIENT',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 0.8),
            ),
          ],
        ),
      );
    } else if (currentStatus == 'En route to patient') {
      return ElevatedButton(
        onPressed: () => _executeTransition('Patient picked up'),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF10B981),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 4,
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.airline_seat_flat_rounded, size: 24),
            SizedBox(width: 10),
            Text(
              'PATIENT PICKED UP / ON BOARD',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 0.8),
            ),
          ],
        ),
      );
    } else if (currentStatus == 'Patient picked up') {
      return ElevatedButton(
        onPressed: () => _executeTransition('En route to hospital'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.blueAccent.shade700,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 4,
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.local_hospital_rounded, size: 24),
            SizedBox(width: 10),
            Text(
              'EN ROUTE TO HOSPITAL',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 0.8),
            ),
          ],
        ),
      );
    } else if (currentStatus == 'En route to hospital') {
      return ElevatedButton(
        onPressed: () => _executeTransition('Arrived / intake'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.purpleAccent.shade700,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 4,
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.how_to_reg_rounded, size: 24),
            SizedBox(width: 10),
            Text(
              'ARRIVED AT ER / INTAKE HANDOVER',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 0.8),
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
