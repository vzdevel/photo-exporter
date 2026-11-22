# Photo Exporter

**Photo Exporter** is an advanced, privacy-first iOS app designed to inspect, edit, organize, and export photos and videos from your iOS Photo Library, Local Files, Google Drive, and Samba (SMB2) shares—preserving accurate EXIF timestamps, timezones, and GPS metadata.

---

## Key Features

- **Multi-Source Media Browser (`MediaSource`)**:
  - Browse and manage **iOS Photo Library**, **Local Folders** (via Security-Scoped Bookmarks with nested folder navigation), **Google Drive** folders, and **Samba (SMB2)** network shares.
  - Perform in-place file rename, 90° clockwise rotation, deletion, and metadata embedding ("Apply") directly inside folder/remote sources.

- **Accurate EXIF & Inferred Timezone Handling**:
  - Automatically parses native EXIF, TIFF, GPS, IPTC, XMP, and QuickTime metadata (including raw TIFF/Exif SubIFD fallback for DNG/RAW `OffsetTime` tags).
  - Detects photos without timestamps or timezone offsets and infers local timezones from photo sequence or GPS/device context.
  - Distinguishes between native timestamps and Photos app adjustments (Date/Time, GPS, Filters, Portrait, Crop/Rotate).

- **Lossless Metadata Injection**:
  - Uses Apple's `CGImageDestinationCopyImageSource` API to embed adjusted/inferred date, time, timezone, and GPS coordinates **without re-encoding or compressing image pixels**.
  - Full support for JPEG, HEIC, TIFF, PNG (with explicit physical-iOS `exif:DateTimeOriginal` XMP injection), and QuickTime MOV/MP4.

- **Date-Based Folder Organization & Smart Deduplication**:
  - Configurable subfolder patterns (`yyyy`, `yyyyMM`, `yyMM`, `yyyy-MM`, `yyyy/MM`, or custom paths).
  - Pre-export analysis checks destination subfolders for duplicates (normalized base name stripped of `-N` / ` (N)`, timestamp tolerance, and file size) and groups naming collisions cleanly into `[Destination]`, `[Original]`, and `[Renamed]` cards.

- **Multi-Destination Export & Background Continuation**:
  - **Local Files**, **Google Drive** (multi-account OAuth 2.0 via `ASWebAuthenticationSession`, `uploadType=resumable` streaming), **Google Photos** (`photoslibrary.appendonly`), and **Samba (SMB2)** (pure-Swift SMB2 client over BSD sockets with Keychain-stored credentials).
  - Shared `ExportBatchRunner` + `BackgroundExportManager` (`BGContinuedProcessingTask`) keeps large exports progressing across app switches, with automatic retries and persistent `"Retry Failed"` recovery.

- **Full-Screen Media Viewer, Streaming & Storage Hygiene**:
  - Single-step expand-and-rotate fullscreen transition, `ZoomableImageView` pinch/double-tap zoom, `DetailVideoPlayer` hosting `AVPlayerViewController` natively, Edited vs. Original switcher, interactive Apple Maps pin, and batch metadata editing.
  - HTTP Range streaming for remote Google Drive videos (`streamingSession` + `GoogleDriveRangeCache`) and connectivity-aware foreground socket flushing.
  - Startup storage sweep (`MetadataCacheService.performStartupStorageSweep`) cleaning orphaned temp files and 30-day expired `FolderCaches/` while preserving Photo Library caches.

---

## Documentation & Site

- **Landing Page**: https://vzdevel.github.io/photo-exporter/
- **Privacy Policy**: https://vzdevel.github.io/photo-exporter/privacy.html
- **[ARCHITECTURE.md](./ARCHITECTURE.md)**: System design, architecture patterns, service layer breakdown, data flow, and model definitions.
- **[FINDINGS_AND_KNOWHOW.md](./FINDINGS_AND_KNOWHOW.md)**: Deep technical findings, ImageIO nuances, PNG XMP compatibility on physical iOS, SMB2 implementation notes, and compiler stability fixes.

---

## Setup & Building

### 1. Signing & Bundle Identifier
1. Copy `Local.xcconfig.example` to `Local.xcconfig` (gitignored):
   ```bash
   cp Local.xcconfig.example Local.xcconfig
   ```
2. Set your Apple Developer Team ID (`DEVELOPMENT_TEAM`) and desired `PRODUCT_BUNDLE_IDENTIFIER` in `Local.xcconfig` (or configure Signing & Capabilities directly in Xcode).

### 2. Google OAuth Configuration (Optional — required for Google Drive / Google Photos)
1. In [Google Cloud Console](https://console.cloud.google.com/), create an **OAuth 2.0 Client ID** of type **iOS** matching your `PRODUCT_BUNDLE_IDENTIFIER`, and enable the **Google Drive API** and/or **Photos Library API**.
2. Copy `GoogleService-Info.plist.example` to `Photo Exporter/GoogleService-Info.plist` (gitignored):
   ```bash
   cp GoogleService-Info.plist.example "Photo Exporter/GoogleService-Info.plist"
   ```
3. Fill in your `CLIENT_ID`, `REVERSED_CLIENT_ID`, and `BUNDLE_ID` in `Photo Exporter/GoogleService-Info.plist`.

### 3. Build in Xcode
Open `Photo Exporter.xcodeproj` in Xcode and build for an iOS simulator or connected device:

```bash
xcodebuild -project "Photo Exporter.xcodeproj" -scheme "Photo Exporter" -configuration Debug -destination "generic/platform=iOS Simulator" build
```

