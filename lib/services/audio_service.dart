import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AudioAlarmService {
  static final AudioAlarmService _instance = AudioAlarmService._internal();
  factory AudioAlarmService() => _instance;
  AudioAlarmService._internal();

  final AudioPlayer _player = AudioPlayer();
  bool _isContextConfigured = false;

  Future<void> _configureAudioContext() async {
    if (_isContextConfigured) return;
    try {
      await _player.setAudioContext(
        AudioContext(
          android: AudioContextAndroid(
            isSpeakerphoneOn: true,
            stayAwake: true,
            contentType: AndroidContentType.sonification,
            usageType: AndroidUsageType.alarm,
            audioFocus: AndroidAudioFocus.gainTransientExclusive,
          ),
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playback,
            options: {
              AVAudioSessionOptions.duckOthers,
              AVAudioSessionOptions.defaultToSpeaker,
            },
          ),
        ),
      );
      _isContextConfigured = true;
    } catch (e) {
      debugPrint('AudioContext configuration error: $e');
    }
  }

  Future<void> playDispatchAlarm() async {
    try {
      HapticFeedback.heavyImpact();
      await _configureAudioContext();
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.setVolume(1.0);
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
