# 🚑 Ambulance Driver & Emergency Telemetry Native App

Native Flutter mobile application for ambulance drivers and emergency medical responders in the Emergency Dispatch Fleet Network.

---

## ⚡ Core Operational Features

1. **Background High-Priority Alerts & Siren (Firebase Cloud Messaging + Lock Screen Wake)**:
   - When the phone is locked, asleep in a pocket, or minimized, FCM delivers a `priority: high` push payload on the `emergency_dispatch` channel.
   - Declares `USE_FULL_SCREEN_INTENT`, waking the screen and ringing the emergency dispatch siren like an incoming phone call even on silent or Do Not Disturb.
   - Automatically registers device FCM tokens in `public.drivers` (`fcm_token` column).

2. **Keep-Alive Foreground Service with Persistent Notification**:
   - While marked "On Duty", a sticky, persistent notification remains active in the Android notification drawer:
     `🚑 Emergency Dispatch Service Active`
     `Unit: [Driver Name] • Transmitting Live GPS Telemetry`
   - Android will never kill the app while the foreground service is active, ensuring continuous GPS telemetry to the dispatcher console.

3. **Off-Duty / On-Duty Quick Toggle**:
   - A prominent `[ 🟢 ON DUTY / ⚪ OFF DUTY ]` switch in the app header and main console.
   - Allows drivers to take breaks or complete shifts.
   - When Off Duty, stops background GPS transmission, clears the sticky notification, and marks the driver offline so dispatchers see true unit availability.

4. **1-Tap Turn-by-Turn Offline Google Navigation Fallback**:
   - Direct launch into Google Maps Turn-by-Turn navigation via `google.navigation:q=lat,lng&mode=d`.
   - Supports offline cached navigation maps, voice guidance, and alternative Waze / in-app tactical vector map fallbacks.

5. **Two-Way Dispatcher-to-Driver Tactical Radio & Quick Canned Messages**:
   - 1-tap glove-friendly canned status alerts during high-stress trauma runs:
     - 🚦 `[ Stuck in Traffic / Road Blocked ]`
     - 🚓 `[ Need Police Escort ]`
     - 🏥 `[ Hospital Divert Requested ]`
     - ⚠️ `[ Patient Deteriorating / Code Blue ]`
     - ⛽ `[ Refueling / Vehicle Delay ]`
   - Instantly triggers a pulsing flash alert on the Dispatcher Web Console (`/dispatcher`).
   - Allows dispatchers to acknowledge with 1 click and transmit radio replies (e.g. `Police Escort Dispatched`, `Hospital Divert Approved`).

6. **Dashboard Wakelock (`wakelock_plus`)**: Keeps the screen awake 100% of the time while mounted on the vehicle dashboard during an active shift.
7. **Hardware Health Telemetry (`battery_plus`, `connectivity_plus`)**: Reports ambulance driver battery percentage, charging state, and network connectivity (WiFi / Cellular / Offline).
8. **Tactile Driver Progression Milestones**: Oversized, high-contrast action buttons:
   - `[1. START RUN: EN ROUTE TO PATIENT]`
   - `[2. PATIENT PICKED UP / ON BOARD]`
   - `[3. EN ROUTE TO HOSPITAL]`
   - `[4. ARRIVED AT ER / INTAKE HANDOVER]`

---

## 🚀 Quick Start Guide

### 1. Install Dependencies
```bash
cd Driver-mobile-app
flutter pub get
```

### 2. Configure Firebase (FCM)
1. In the [Firebase Console](https://console.firebase.google.com/), create a project or use an existing one.
2. Add an Android app with package name: `com.ems.dispatch.ambulance_driver_app`.
3. Download `google-services.json` and place it in `Driver-mobile-app/android/app/google-services.json` (see `google-services.json.example` for format).

### 3. Build Production Release APK for Driver Phones
```bash
flutter build apk --release --no-tree-shake-icons
```
The output APK will be generated at:
`build/app/outputs/flutter-apk/app-release.apk`

---

## ⚙️ Backend Database & Edge Function Configuration

- **Database Migrations**: Run `supabase/migrations/20261002_driver_fcm_and_canned_alerts.sql` in Supabase SQL Editor.
- **FCM Dispatch Edge Function**: Deploy `supabase/functions/dispatch-fcm-alert/index.ts` to Supabase Edge Functions with secret `FCM_SERVER_KEY`.
