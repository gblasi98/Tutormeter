# Tutormeter — iOS Speed Monitoring

Real-time average speed monitoring for speed camera (Tutor) zones on Italian highways.

> **iOS 17+** · **Swift 5.10** · **Xcode 16** · **106+ tests** · Tutormeter

---

## What It Does

Tutormeter shows your **average speed** while driving through speed camera zones (Tutor/Autovelox). It works alongside Waze or any navigation app, displaying speed in the **Dynamic Island**, **Lock Screen**, or **CarPlay dashboard**.

- 🔴 Alerts when you exceed the 130 km/h limit
- 🟡 Dead reckoning via IMU when GPS is lost (tunnels)
- 🟢 Confidence indicator from Kalman filter fusion

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                    TutormeterApp.swift                     │
│            (SwiftUI entry + deep links)               │
└──────────┬──────────────────────────────┬────────────┘
           │                              │
    ┌──────▼──────┐              ┌────────▼────────┐
    │  ContentView │              │   AppDelegate   │
    │  (main UI)   │              │  (lifecycle)    │
    └──────┬───────┘              └────────┬────────┘
           │                              │
    ┌──────▼──────────────────────────────▼────────────┐
    │              TrackingManager                     │
    │           (central orchestrator)                 │
    └──┬──────────┬──────────┬──────────┬─────────────┘
       │          │          │          │
  ┌────▼───┐ ┌───▼────┐ ┌───▼────┐ ┌───▼──────────┐
  │Location│ │  IMU   │ │ State  │ │ Live Activity │
  │Tracker │ │ Filter │ │Machine │ │   Manager     │
  └────┬───┘ └───┬────┘ └────────┘ └───────┬───────┘
       │         │                          │
  ┌────▼─────────▼────┐              ┌──────▼───────┐
  │  SpeedCalculator  │              │ Dynamic Isl. │
  │  + KalmanFilter   │              │ + LockScreen │
  └───────────────────┘              └──────────────┘
```

### Key Components

| Component | Responsibility |
|---|---|
| `SpeedCalculator` | Haversine distance, KF fusion, average speed |
| `KalmanFilter1D` | 1D predict/update with covariance |
| `LocationTracker` | CLLocationManager: 1Hz, automotive, background |
| `IMUFilter` | CMMotionManager: gravity comp, low-pass, longitudinal projection |
| `CalibrationManager` | Auto-calibration of accelerometer bias at session start |
| `StateMachine` | FSM: idle→active→tracking→gpsLost→completed |
| `LiveActivityManager` | Dynamic Island + Lock Screen lifecycle |
| `BackgroundTaskManager` | BGTaskScheduler: refresh (15min) + cleanup (2h) |
| `SessionStore` | UserDefaults persistence for state, calibration, stats |
| `TrackingManager` | Central orchestrator for all components |
| `CarPlay` | Dashboard template for in-vehicle display |

### Sensor Fusion

```
GPS (1Hz) ──→ Haversine ──→ Position ──→ KF.update() ──┐
IMU (100Hz) ──→ Low-pass ──→ Accel ──→ KF.predict() ──┤
                                                         ├──→ avg speed
                                                         └──→ confidence
```

---

## Project Structure

```
Velox/
├── project.yml                 # XcodeGen spec
├── codemagic.yaml              # CI/CD (dev, TestFlight, PR)
├── SETUP.md                    # App Store Connect + Codemagic guide
├── Velox/
│   ├── App/
│   │   ├── VeloxApp.swift      # @main entry point
│   │   ├── AppDelegate.swift   # UIApplicationDelegate
│   │   ├── AppIntents.swift    # Siri Shortcuts + TrackingManager
│   │   ├── DeepLinkHandler.swift
│   │   └── Info.plist
│   ├── Core/
│   │   ├── SpeedCalculator.swift
│   │   ├── KalmanFilter1D.swift
│   │   ├── StateMachine.swift
│   │   ├── CalibrationManager.swift
│   │   ├── BackgroundTaskManager.swift
│   │   └── SessionStore.swift
│   ├── Services/
│   │   ├── LocationTracker.swift
│   │   └── IMUFilter.swift
│   ├── UI/
│   │   └── LiveActivity/
│   │       ├── VeloxLiveActivity.swift
│   │       ├── LiveActivityManager.swift
│   │       └── LockScreenWidget.swift
│   └── CarPlay/
│       ├── CarPlaySceneDelegate.swift
│       └── CarPlayManager.swift
└── Tests/
    ├── SpeedCalculatorTests.swift      (34 tests)
    ├── LocationTrackerTests.swift      (27 tests)
    ├── AppIntentsTests.swift           (13 tests)
    ├── LiveActivityTests.swift         (11 tests)
    ├── BackgroundTaskTests.swift       (11 tests)
    └── IntegrationTests.swift          (10 tests)
```

---

## Quick Start

### Prerequisites

- macOS with Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- CocoaPods or SPM (not required — all Apple frameworks)

### Build & Run

```bash
# Generate Xcode project
xcodegen generate --spec project.yml

# Open in Xcode
open Tutormeter.xcodeproj

# Run tests
xcodebuild test \
  -project Tutormeter.xcodeproj \
  -scheme Tutormeter \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
```

### CI/CD (Codemagic)

1. Push to GitHub
2. Connect repo on [codemagic.io](https://codemagic.io)
3. Add encrypted environment variables (see [SETUP.md](SETUP.md))
4. Push → auto-build → TestFlight

---

## Test Coverage

```
106 tests across 8 test files

HaversineDistance       6 tests   (equator, antimeridian, pole)
KalmanFilter1D         9 tests   (predict, update, converge, diverge)
SpeedCalculator        7 tests   (KF integration, tunnel, confidence)
CalibrationManager     3 tests   (noise, bias, validation)
LocationTracker       27 tests   (auth, errors, fix quality, state machine)
AppIntents            13 tests   (deep links, tracking lifecycle, UI mapping)
LiveActivity          11 tests   (state formatting, attributes, manager)
BackgroundTask        11 tests   (session store, recovery, lifetime stats)
Integration           10 tests   (full session, GPS loss/recovery, KF convergence)
```

---

## Permissions Required

| Permission | Purpose |
|---|---|
| `NSLocationWhenInUseUsageDescription` | Speed calculation during active use |
| `NSLocationAlwaysAndWhenInUseUsageDescription` | Background tracking with navigation apps |
| `NSMotionUsageDescription` | IMU dead reckoning in tunnels |
| `NSSiriUsageDescription` | Voice commands for start/stop |

### Background Modes

- `location` — continuous GPS in background
- `audio` — keep app alive during navigation
- `fetch` — periodic state refresh (BGTaskScheduler)
- `car-play` — in-vehicle dashboard display

---

## Privacy

- **All data stays on-device** — no servers, no analytics, no tracking
- Speed data is stored locally via UserDefaults and SwiftData
- App Transport Security: no network calls made
- `ITSAppUsesNonExemptEncryption`: NO

---

## License

Proprietary — all rights reserved.
