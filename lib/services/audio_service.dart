import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

class AudioAlarmService {
  static final AudioAlarmService _instance = AudioAlarmService._internal();
  factory AudioAlarmService() => _instance;
  AudioAlarmService._internal();

  final AudioPlayer _player = AudioPlayer();

  Future<void> playDispatchAlarm() async {
    try {
      // Plays a standard priority alert tone
      await _player.setReleaseMode(ReleaseMode.stop);
      // Play high-frequency alert sound
      await _player.play(UrlSource('https://cdn.freesound.org/previews/250/250629_4486188-lq.mp3'));
    } catch (e) {
      debugPrint('Audio playback error (will continue safely): $e');
    }
  }

  Future<void> stopAlarm() async {
    try {
      await _player.stop();
    } catch (_) {}
  }
}
