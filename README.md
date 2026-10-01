# 🚑 Ambulance Driver & Emergency Telemetry Native App

Native Flutter mobile application for ambulance drivers and emergency medical responders in the Emergency Dispatch Fleet Network.

---

## ⚡ Core Operational Features

1. **Dashboard Wakelock (`wakelock_plus`)**: Keeps the screen awake 100% of the time while mounted on the vehicle dashboard.
2. **High-Accuracy Background Telemetry (`geolocator`)**: Streams real-time GPS coordinates, heading, and speed (km/h) to the Dispatcher Ops Board every 5 seconds.
3. **Hardware Health Telemetry (`battery_plus`, `connectivity_plus`)**: Reports ambulance driver battery percentage, charging state, and network connectivity (WiFi / 4G / Offline).
4. **One-Tap Turn-by-Turn Navigation**: Launches Google Maps navigation directly to the exact patient GPS coordinates or receiving hospital.
5. **Real-time Dispatch Siren Alert**: Audio alarm sound rings out immediately when a dispatcher assigns an emergency to this ambulance unit.
6. **Tactile Driver Progression Buttons**: Glove-friendly, high-contrast, oversized action buttons for fast status transitions:
   - `[ARRIVED AT SCENE]`
   - `[PATIENT ONBOARD / EN ROUTE TO HOSPITAL]`
   - `[ARRIVED AT HOSPITAL & HANDED OVER]`

---

## 🚀 Quick Start Guide

### 1. Install Dependencies
```bash
flutter pub get
```

### 2. Run in Debug Mode (on Connected Android Device or Emulator)
```bash
flutter run
```

### 3. Build Production Release APK for Driver Phones
```bash
flutter build apk --release
```
The output APK will be generated at:
`build/app/outputs/flutter-apk/app-release.apk`

Transfer this APK to your ambulance drivers' Android phones via WhatsApp, Google Drive, or USB to install.

---

## ⚙️ Configuration & Backend Setup

The app connects to the Supabase emergency dispatch backend. Credentials are pre-configured in `lib/config/supabase_config.dart`.

To customize or connect to your own Supabase project:
```dart
class SupabaseConfig {
  static const String url = 'https://YOUR_PROJECT.supabase.co';
  static const String anonKey = 'YOUR_PUBLISHABLE_ANON_KEY';
}
```
