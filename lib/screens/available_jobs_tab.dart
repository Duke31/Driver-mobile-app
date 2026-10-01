import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/emergency_request.dart';

class AvailableJobsTab extends StatefulWidget {
  final List<EmergencyRequestModel> availableJobs;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback onRefresh;
  final Function(EmergencyRequestModel) onMissionAccepted;

  const AvailableJobsTab({
    super.key,
    required this.availableJobs,
    required this.isLoading,
    this.errorMessage,
    required this.onRefresh,
    required this.onMissionAccepted,
  });

  @override
  State<AvailableJobsTab> createState() => _AvailableJobsTabState();
}

class _AvailableJobsTabState extends State<AvailableJobsTab> {
  String? _acceptingId;
  String? _actionError;

  Future<void> _acceptJob(EmergencyRequestModel job) async {
    setState(() {
      _acceptingId = job.id;
      _actionError = null;
    });

    try {
      final res = await Supabase.instance.client.rpc('accept_emergency_mission', params: {
        'p_request_id': job.id,
      });

      debugPrint('Mission accepted: $res');
      widget.onMissionAccepted(job);
    } catch (e) {
      String clean = e.toString();
      if (clean.contains('Exception:')) {
        clean = clean.split('Exception:').last.trim();
      }
      setState(() {
        _actionError = clean;
      });
    } finally {
      if (mounted) {
        setState(() => _acceptingId = null);
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

    if (widget.availableJobs.isEmpty) {
      return RefreshIndicator(
        color: Colors.redAccent,
        onRefresh: () async => widget.onRefresh(),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(32.0),
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
                            'Queue Sync Notice',
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
              const SizedBox(height: 30),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white12),
                ),
                child: const Icon(
                  Icons.inbox_rounded,
                  color: Colors.white38,
                  size: 54,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'No Available Jobs in Queue',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'When dispatchers broadcast a new emergency run or send out an open dispatch, it will appear here instantly with an audible alert chime.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF94A3B8),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: widget.onRefresh,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Check for New Dispatches'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E293B),
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      color: Colors.redAccent,
      onRefresh: () async => widget.onRefresh(),
      child: ListView.separated(
        padding: const EdgeInsets.all(16.0),
        itemCount: widget.availableJobs.length + (_actionError != null ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 14),
        itemBuilder: (context, index) {
          if (_actionError != null && index == 0) {
            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade900.withOpacity(0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
              ),
              child: Text(
                _actionError!,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            );
          }

          final jobIndex = _actionError != null ? index - 1 : index;
          final job = widget.availableJobs[jobIndex];
          final isAccepting = _acceptingId == job.id;

          return Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: job.priority == '1'
                    ? Colors.redAccent.withOpacity(0.8)
                    : Colors.white.withOpacity(0.08),
                width: job.priority == '1' ? 1.5 : 1.0,
              ),
            ),
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        job.priority != null ? 'PRIORITY ${job.priority}' : 'BROADCAST',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                          color: Colors.redAccent,
                        ),
                      ),
                    ),
                    Text(
                      job.status.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.amberAccent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  job.emergencyType ?? 'Emergency Medical Call',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),

                // Patient pickup address
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.location_on_rounded, color: Colors.redAccent, size: 18),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        job.patientAddress ?? 'Patient address pending dispatch note',
                        style: const TextStyle(fontSize: 13, color: Colors.white),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),

                // Destination hospital
                Row(
                  children: [
                    const Icon(Icons.local_hospital_rounded, color: Colors.lightBlueAccent, size: 18),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Hospital: ${job.hospitalName}',
                        style: const TextStyle(fontSize: 13, color: Colors.white70),
                      ),
                    ),
                  ],
                ),

                if (job.notes != null && job.notes!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Triage: ${job.notes}',
                      style: const TextStyle(fontSize: 12, color: Colors.white70),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                const SizedBox(height: 14),

                // Accept Call Action Button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: isAccepting ? null : () => _acceptJob(job),
                    icon: isAccepting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                          )
                        : const Icon(Icons.check_circle_rounded, size: 20),
                    label: Text(
                      isAccepting ? 'CLAIMING MISSION...' : '🚨 ACCEPT EMERGENCY RUN',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 0.5),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.redAccent.withOpacity(0.5),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 2,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
