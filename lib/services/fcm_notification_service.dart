import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Top-level background handler for FCM messages when app is terminated or in background
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('Handling background FCM dispatch: ${message.messageId}');
  try {
    await Firebase.initializeApp();
  } catch (_) {}

  final notificationPlugin = FlutterLocalNotificationsPlugin();
  
  // Show instant high-importance notification waking up device
  const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'emergency_dispatch',
    'Emergency Dispatch Siren & Run Alerts',
    icon: 'ic_stat_notification',
    color: Color(0xFFFF334B),
    channelDescription: 'High-priority EMS emergency dispatch alerts with siren and lockscreen wake',
    importance: Importance.max,
    priority: Priority.max,
    fullScreenIntent: true,
    category: AndroidNotificationCategory.alarm,
    visibility: NotificationVisibility.public,
    enableVibration: true,
    playSound: true,
    styleInformation: BigTextStyleInformation(''),
  );

  const NotificationDetails notificationDetails = NotificationDetails(android: androidDetails);

  final title = message.notification?.title ?? message.data['emergency_type'] ?? 'EMERGENCY DISPATCH RUN';
  final body = message.notification?.body ?? message.data['patient_address'] ?? 'New emergency assigned. Respond immediately.';

  await notificationPlugin.show(
    911,
    '🚨 $title',
    body,
    notificationDetails,
    payload: message.data['id']?.toString(),
  );
}

class FcmNotificationService {
  static final FcmNotificationService _instance = FcmNotificationService._internal();
  factory FcmNotificationService() => _instance;
  FcmNotificationService._internal();

  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;
  String? _fcmToken;
  String? _currentDriverId;

  String? get fcmToken => _fcmToken;

  static const String emergencyChannelId = 'emergency_dispatch';
  static const String dutyChannelId = 'driver_duty_telemetry';
  static const int dutyNotificationId = 112;

  Future<void> initialize() async {
    if (_isInitialized) return;

    // 1. Initialize Local Notifications Plugin
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('ic_stat_notification');
    const InitializationSettings initSettings = InitializationSettings(android: androidSettings);

    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        debugPrint('Notification clicked with payload: ${response.payload}');
      },
    );

    // 2. Create High-Priority Emergency Channel & Foreground Duty Channel
    final AndroidNotificationChannel emergencyChannel = const AndroidNotificationChannel(
      emergencyChannelId,
      'Emergency Dispatch Siren & Run Alerts',
      description: 'Used for critical incoming emergency mission alerts',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    );

    final AndroidNotificationChannel dutyChannel = const AndroidNotificationChannel(
      dutyChannelId,
      'Ambulance Duty & Telemetry Service',
      description: 'Sticky keep-alive status notification while ambulance driver is on duty',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
      showBadge: false,
    );

    final androidImplementation = _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

    if (androidImplementation != null) {
      await androidImplementation.createNotificationChannel(emergencyChannel);
      await androidImplementation.createNotificationChannel(dutyChannel);
      // Request notification permission on Android 13+
      await androidImplementation.requestNotificationsPermission();
    }

    // 3. Initialize Firebase Cloud Messaging safely (handles missing google-services.json gracefully)
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      final messaging = FirebaseMessaging.instance;

      // Request user push permissions
      final NotificationSettings settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        criticalAlert: true,
        provisional: false,
      );

      debugPrint('FCM Authorization Status: ${settings.authorizationStatus}');

      // Get device FCM registration token
      _fcmToken = await messaging.getToken();
      debugPrint('Device FCM Token: $_fcmToken');

      // Listen for incoming foreground push notifications
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('Foreground FCM message received: ${message.data}');
        showEmergencyDispatchAlert(
          title: message.notification?.title ?? message.data['emergency_type'] ?? 'EMERGENCY DISPATCH',
          body: message.notification?.body ?? message.data['patient_address'] ?? 'Immediate response required.',
          payload: message.data['id']?.toString(),
        );
      });

      // Listen for token updates
      messaging.onTokenRefresh.listen((newToken) {
        _fcmToken = newToken;
        if (_currentDriverId != null) {
          _syncTokenToSupabase(_currentDriverId!, newToken);
        }
      });
    } catch (e) {
      debugPrint('Firebase messaging initialization note (Google Services setup pending): $e');
    }

    _isInitialized = true;
  }

  /// Register current driver ID and sync FCM token to Supabase public.drivers
  Future<void> registerDriver(String driverId) async {
    _currentDriverId = driverId;
    if (_fcmToken != null && _fcmToken!.isNotEmpty) {
      await _syncTokenToSupabase(driverId, _fcmToken!);
    } else {
      try {
        final token = await FirebaseMessaging.instance.getToken();
        if (token != null) {
          _fcmToken = token;
          await _syncTokenToSupabase(driverId, token);
        }
      } catch (e) {
        debugPrint('FCM getToken note: $e');
      }
    }
  }

  Future<void> _syncTokenToSupabase(String driverId, String token) async {
    try {
      await Supabase.instance.client.rpc('update_driver_fcm_token', params: {
        'p_driver_id': driverId,
        'p_fcm_token': token,
      });
      debugPrint('Successfully registered driver FCM token in database.');
    } catch (e) {
      // Fallback direct update if RPC is pending
      try {
        await Supabase.instance.client
            .from('drivers')
            .update({'fcm_token': token, 'last_active_at': DateTime.now().toIso8601String()})
            .eq('id', driverId);
        debugPrint('Direct update registered driver FCM token.');
      } catch (directErr) {
        debugPrint('Failed to sync FCM token to Supabase: $directErr');
      }
    }
  }

  /// Feature A: Keep-Alive Sticky Foreground Notification while Driver is On Duty
  Future<void> showPersistentDutyNotification({
    required String driverName,
    required String? vehicleLabel,
  }) async {
    try {
      final unit = vehicleLabel?.isNotEmpty == true ? vehicleLabel! : 'Ambulance Unit';
      final androidDetails = AndroidNotificationDetails(
        dutyChannelId,
        'Ambulance Duty & Telemetry Service',
        icon: 'ic_stat_notification',
        color: const Color(0xFF00D4FF),
        channelDescription: 'Sticky status notification keeping background GPS telemetry alive',
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        autoCancel: false,
        showWhen: true,
        category: AndroidNotificationCategory.service,
        subText: 'EMS Ops Active',
        styleInformation: BigTextStyleInformation(
          'Unit: $driverName ($unit)\nTransmitting continuous live GPS telemetry & awaiting dispatch.',
          contentTitle: '🚑 Emergency Dispatch Service Active',
          summaryText: 'On Duty • GPS Active',
        ),
      );

      final NotificationDetails notificationDetails = NotificationDetails(android: androidDetails);

      await _localNotifications.show(
        dutyNotificationId,
        '🚑 Emergency Dispatch Service Active',
        'Unit: $driverName • Transmitting Live GPS Telemetry',
        notificationDetails,
      );
    } catch (e) {
      debugPrint('Error showing persistent duty notification: $e');
    }
  }

  /// Cancel Sticky Foreground Notification when Driver switches Off Duty
  Future<void> cancelPersistentDutyNotification() async {
    try {
      await _localNotifications.cancel(dutyNotificationId);
    } catch (e) {
      debugPrint('Error cancelling duty notification: $e');
    }
  }

  /// Show High-Priority Full Screen Intent Emergency Alert with Siren
  Future<void> showEmergencyDispatchAlert({
    required String title,
    required String body,
    String? payload,
  }) async {
    try {
      const androidDetails = AndroidNotificationDetails(
        emergencyChannelId,
        'Emergency Dispatch Siren & Run Alerts',
        icon: 'ic_stat_notification',
        color: Color(0xFFFF334B),
        channelDescription: 'High-priority EMS emergency dispatch alerts with siren and lockscreen wake',
        importance: Importance.max,
        priority: Priority.max,
        fullScreenIntent: true,
        category: AndroidNotificationCategory.alarm,
        visibility: NotificationVisibility.public,
        enableVibration: true,
        playSound: true,
        styleInformation: BigTextStyleInformation(''),
      );

      const NotificationDetails details = NotificationDetails(android: androidDetails);

      await _localNotifications.show(
        911,
        '🚨 $title',
        body,
        details,
        payload: payload,
      );
    } catch (e) {
      debugPrint('Error showing emergency dispatch alert: $e');
    }
  }
}
