import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/emergency_request.dart';
import '../models/driver_model.dart';

class TacticalMissionMap extends StatefulWidget {
  final EmergencyRequestModel mission;
  final DriverModel driver;
  final double height;
  final bool isHeadingToHospital;
  final VoidCallback? onToggleFullscreen;
  final bool isFullscreen;

  const TacticalMissionMap({
    super.key,
    required this.mission,
    required this.driver,
    this.height = 280,
    required this.isHeadingToHospital,
    this.onToggleFullscreen,
    this.isFullscreen = false,
  });

  @override
  State<TacticalMissionMap> createState() => _TacticalMissionMapState();
}

class _TacticalMissionMapState extends State<TacticalMissionMap> {
  final MapController _mapController = MapController();
  Position? _currentPosition;
  StreamSubscription<Position>? _positionStream;
  double _distanceMeters = 0;
  int _estimatedMinutes = 0;

  @override
  void initState() {
    super.initState();
    _initLiveLocation();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    super.dispose();
  }

  void _initLiveLocation() async {
    try {
      final pos = await Geolocator.getLastKnownPosition() ?? await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      if (pos != null && mounted) {
        setState(() {
          _currentPosition = pos;
          _updateDistance();
        });
      }
    } catch (_) {}

    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((Position pos) {
      if (mounted) {
        setState(() {
          _currentPosition = pos;
          _updateDistance();
        });
      }
    });
  }

  LatLng? get _targetLatLng {
    if (widget.isHeadingToHospital) {
      if (widget.mission.hospitalLat != null && widget.mission.hospitalLng != null) {
        return LatLng(widget.mission.hospitalLat!, widget.mission.hospitalLng!);
      }
    } else {
      if (widget.mission.patientLat != null && widget.mission.patientLng != null) {
        return LatLng(widget.mission.patientLat!, widget.mission.patientLng!);
      }
    }
    return null;
  }

  void _updateDistance() {
    if (_currentPosition == null) return;
    final target = _targetLatLng;
    if (target == null) return;

    final meters = Geolocator.distanceBetween(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
      target.latitude,
      target.longitude,
    );

    setState(() {
      _distanceMeters = meters;
      // Estimate at ~45 km/h emergency transit speed
      _estimatedMinutes = ((meters / 1000) / 45 * 60).clamp(1, 180).round();
    });
  }

  void _centerOn(LatLng point) {
    _mapController.move(point, 15.0);
  }

  void _fitBounds() {
    final target = _targetLatLng;
    if (_currentPosition != null && target != null) {
      final bounds = LatLngBounds.fromPoints([
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
        target,
      ]);
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.all(50),
        ),
      );
    } else if (target != null) {
      _centerOn(target);
    } else if (_currentPosition != null) {
      _centerOn(LatLng(_currentPosition!.latitude, _currentPosition!.longitude));
    }
  }

  Future<void> _launchExternalNavigation() async {
    final target = _targetLatLng;
    final targetAddress = widget.isHeadingToHospital
        ? widget.mission.hospitalAddress ?? widget.mission.hospitalName
        : widget.mission.patientAddress;

    // 1. Try native Google Navigation intent
    if (target != null) {
      final navUri = Uri.parse('google.navigation:q=${target.latitude},${target.longitude}&mode=d');
      try {
        if (await launchUrl(navUri, mode: LaunchMode.externalNonBrowserApplication)) return;
      } catch (_) {}
    } else if (targetAddress != null && targetAddress.isNotEmpty) {
      final navUri = Uri.parse('google.navigation:q=${Uri.encodeComponent(targetAddress)}&mode=d');
      try {
        if (await launchUrl(navUri, mode: LaunchMode.externalNonBrowserApplication)) return;
      } catch (_) {}
    }

    // 2. Fallback to Google Maps Web / App URL
    Uri webUri;
    if (target != null) {
      webUri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${target.latitude},${target.longitude}');
    } else {
      webUri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${Uri.encodeComponent(targetAddress ?? "Emergency Location")}');
    }

    try {
      await launchUrl(webUri, mode: LaunchMode.externalApplication);
    } catch (_) {
      await launchUrl(webUri, mode: LaunchMode.platformDefault);
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = _targetLatLng;
    final ambulanceLatLng = _currentPosition != null
        ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
        : null;

    final initialCenter = target ?? ambulanceLatLng ?? const LatLng(9.0820, 8.6753); // Default coordinate fallback

    final List<Marker> markers = [];

    // 1. Ambulance Live Location Marker
    if (ambulanceLatLng != null) {
      markers.add(
        Marker(
          point: ambulanceLatLng,
          width: 56,
          height: 56,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFF34D399), width: 1),
                ),
                child: const Text(
                  'YOU',
                  style: TextStyle(color: Color(0xFF34D399), fontSize: 9, fontWeight: FontWeight.bold),
                ),
              ),
              const Icon(
                Icons.navigation_rounded,
                color: Color(0xFF34D399),
                size: 28,
              ),
            ],
          ),
        ),
      );
    }

    // 2. Patient Marker
    if (widget.mission.patientLat != null && widget.mission.patientLng != null) {
      markers.add(
        Marker(
          point: LatLng(widget.mission.patientLat!, widget.mission.patientLng!),
          width: 70,
          height: 70,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red.shade900,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.redAccent, width: 1),
                ),
                child: const Text(
                  'PATIENT',
                  style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                ),
              ),
              const Icon(
                Icons.emergency_rounded,
                color: Colors.redAccent,
                size: 32,
              ),
            ],
          ),
        ),
      );
    }

    // 3. Hospital Marker
    if (widget.mission.hospitalLat != null && widget.mission.hospitalLng != null) {
      markers.add(
        Marker(
          point: LatLng(widget.mission.hospitalLat!, widget.mission.hospitalLng!),
          width: 70,
          height: 70,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.blue.shade900,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.lightBlueAccent, width: 1),
                ),
                child: const Text(
                  'HOSPITAL',
                  style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                ),
              ),
              const Icon(
                Icons.local_hospital_rounded,
                color: Colors.lightBlueAccent,
                size: 30,
              ),
            ],
          ),
        ),
      );
    }

    // Polyline connecting points
    final List<Polyline> polylines = [];
    if (ambulanceLatLng != null && target != null) {
      polylines.add(
        Polyline(
          points: [ambulanceLatLng, target],
          color: widget.isHeadingToHospital ? Colors.lightBlueAccent : Colors.redAccent,
          strokeWidth: 4.0,
        ),
      );
    }

    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: widget.isHeadingToHospital ? Colors.blueAccent.withOpacity(0.5) : Colors.redAccent.withOpacity(0.5),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: initialCenter,
              initialZoom: 13.5,
              minZoom: 3,
              maxZoom: 18,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.ems.dispatch.ambulance_driver_app',
              ),
              if (polylines.isNotEmpty) PolylineLayer(polylines: polylines),
              MarkerLayer(markers: markers),
            ],
          ),

          // Top Telemetry Header (Distance & ETA)
          Positioned(
            top: 10,
            left: 10,
            right: 10,
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A).withOpacity(0.92),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          widget.isHeadingToHospital ? Icons.local_hospital_rounded : Icons.person_pin_circle_rounded,
                          color: widget.isHeadingToHospital ? Colors.lightBlueAccent : Colors.redAccent,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            _distanceMeters > 0
                                ? '${(_distanceMeters / 1000).toStringAsFixed(1)} km • ~$_estimatedMinutes min ETA'
                                : (widget.isHeadingToHospital ? 'Hospital Transit' : 'Patient Pickup'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (widget.onToggleFullscreen != null)
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A).withOpacity(0.92),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: IconButton(
                      icon: Icon(
                        widget.isFullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                      padding: const EdgeInsets.all(6),
                      constraints: const BoxConstraints(),
                      tooltip: widget.isFullscreen ? 'Exit Fullscreen' : 'Expand Map',
                      onPressed: widget.onToggleFullscreen,
                    ),
                  ),
              ],
            ),
          ),

          // Floating Action Buttons (Fit Bounds, Center, External Maps)
          Positioned(
            bottom: 10,
            right: 10,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'map_fit_bounds_${widget.isFullscreen}',
                  backgroundColor: const Color(0xFF0F172A),
                  foregroundColor: Colors.white,
                  tooltip: 'Fit Mission Route',
                  onPressed: _fitBounds,
                  child: const Icon(Icons.zoom_out_map_rounded, size: 18),
                ),
                const SizedBox(height: 6),
                FloatingActionButton.small(
                  heroTag: 'map_center_ambulance_${widget.isFullscreen}',
                  backgroundColor: const Color(0xFF0F172A),
                  foregroundColor: const Color(0xFF34D399),
                  tooltip: 'Center on Ambulance',
                  onPressed: () {
                    if (ambulanceLatLng != null) _centerOn(ambulanceLatLng);
                  },
                  child: const Icon(Icons.my_location_rounded, size: 18),
                ),
                const SizedBox(height: 6),
                FloatingActionButton.extended(
                  heroTag: 'map_launch_nav_${widget.isFullscreen}',
                  backgroundColor: widget.isHeadingToHospital ? Colors.blueAccent : Colors.redAccent,
                  foregroundColor: Colors.white,
                  icon: const Icon(Icons.navigation_rounded, size: 16),
                  label: Text(
                    widget.isHeadingToHospital ? 'GPS Nav' : 'GPS Nav',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                  onPressed: _launchExternalNavigation,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
