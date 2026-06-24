# lm_video_download

A premium, robust, and high-performance Flutter package for downloading HLS (`.m3u8`) video streams offline across **Android, iOS, macOS, Windows, and Web**. 

Features pure-Dart segment parsing, concurrent segment downloads via worker pools, built-in AES-128 decryption, persistent task metadata for auto-resume, and a lightweight loopback local server for seamless offline video playback (crucial for iOS `AVPlayer` restrictions).

---

## Features

*   ⚡ **Concurrent Downloads**: Worker pool architecture to download multiple segments (`.ts`) simultaneously to maximize bandwidth usage.
*   🔒 **AES-128 Decryption**: Automatically fetches key/IV and decrypts segments inline (AES-128-CBC) before saving them.
*   ⏯️ **Pause & Resume**: Automatically saves metadata so tasks can resume exactly where they left off when connection is restored.
*   🌐 **Local HTTP server**: Built-in localhost server to stream local HLS directories offline (resolves `AVPlayer` file sandbox playback limitations on iOS).
*   📂 **Flexible Storage**: Supports merging downloaded segments into a single `.ts` file or keeping the HLS folder structure.
*   🔄 **CDN Token Renewal**: Supports refreshing expired presigned CDN URLs mid-download through an expiration callback.
*   📉 **Speed & Progress Tracking**: Real-time progress percentage, downloaded segments, and download speed (KB/s).
*   🛡️ **Error Handling**: Graceful recovery for network issues, storage full, and encryption failures.

---

## Platform Support & Directory Mappings

| Platform | Supported | Default Download Location | Permissions Required |
| :--- | :---: | :--- | :--- |
| **Android** | Yes | App's External Download sandbox directory | `INTERNET`, `FOREGROUND_SERVICE` (optional, for background downloading) |
| **iOS** | Yes | App's Sandboxed Documents directory | None |
| **macOS** | Yes | User's `Downloads` directory | macOS Sandbox Network Client & Downloads read/write |
| **Windows** | Yes | User's `Downloads` directory | None |
| **Web** | Yes | Browser Memory/Blob download trigger | None |

---

## Getting Started

### 1. Installation

Add `lm_video_download` to your `pubspec.yaml`:

```yaml
dependencies:
  lm_video_download: ^1.0.0
```

### 2. Platform Permissions Setup

#### Android
Add the following to your `AndroidManifest.xml` if you want to support downloading while the app is in the background or show notifications:
```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<!-- Required for Android 13+ if showing progress notifications -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

#### iOS
No special permission is needed to save videos within the app sandbox. If you wish to save/export videos to the Photos library, add this to `Info.plist`:
```xml
<key>NSPhotoLibraryAddUsageDescription</key>
<string>We need access to your photo library to save downloaded videos.</string>
```

#### macOS
Ensure you have activated Network and File access in `macos/Runner/DebugProfile.entitlements` and `Release.entitlements`:
```xml
<key>com.apple.security.files.downloads.read-write</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

---

## Usage

### 1. Initialize Downloader

Initialize the downloader on app startup to restore any unfinished download tasks:

```dart
import 'package:lm_video_download/lm_video_download.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await HlsDownloader.instance.initialize(
    maxConcurrentDownloads: 5, // Concurrent download threads (default: 3)
    enableLogging: true,
  );
  
  runApp(const MyApp());
}
```

### 2. Create and Start Download Task

You can download HLS streams either by merging all TS segments into a single file or by maintaining the HLS directory structure (recommended for offline streaming on iOS).

```dart
// Create a new task
final task = await HlsDownloader.instance.createDownload(
  taskId: 'my_video_123',
  m3u8Url: 'https://example.com/videos/stream.m3u8',
  fileName: 'my_holiday_video.ts', // Output file name if merged
  downloadMode: HlsDownloadMode.mergeAsSingleFile, // or keepFolderStructure
  headers: {
    'Authorization': 'Bearer token_here',
    'User-Agent': 'FlutterApp/1.0.0',
  },
);

// Listen to progress changes
task.progressStream.listen((progress) {
  print('Progress: ${progress.percentage.toStringAsFixed(1)}%');
  print('Speed: ${progress.downloadSpeedKbps.toStringAsFixed(1)} KB/s');
  print('Segments: ${progress.downloadedSegments}/${progress.totalSegments}');
});

// Listen to task state changes
task.stateStream.listen((state) {
  print('Task state changed to: $state');
});

// Start the download
await task.start();
```

### 3. Handle Expired CDN URLs

If your HLS video uses presigned URLs with short-lived tokens, you can implement `onUrlExpired` callback to automatically fetch and update the download token mid-progress without losing downloaded segments.

```dart
await task.start(
  onUrlExpired: () async {
    // Call your API to get a fresh URL with a new secure token
    final freshM3u8Url = await api.getFreshVideoUrl('my_video_123');
    return freshM3u8Url; 
  },
);
```

### 4. Task Management

```dart
// Pause download
await task.pause();

// Resume download (will skip already downloaded segments automatically)
await task.start();

// Cancel and remove temporary download files
await task.cancel();

// Delete completely from disk
await task.delete();
```

### 5. Play Offline HLS Video on iOS / Android via Local Server

Since the native iOS `AVPlayer` does not support playing local files with `.m3u8` extensions directly due to sandbox constraints, use the built-in local web server:

```dart
void playVideoOffline(String taskId) async {
  // Start the local web server
  final server = await HlsDownloader.instance.startLocalServer();
  
  // Get localhost URL mapping to local files
  final offlinePlaybackUrl = server.getPlaybackUrl('$taskId/index.m3u8');
  print('Offline Playback URL: $offlinePlaybackUrl');
  // Output: http://127.0.0.1:8080/my_video_123/index.m3u8
  
  // Feed this URL directly to your Flutter VideoPlayer or BetterPlayer
  _controller = VideoPlayerController.networkUrl(Uri.parse(offlinePlaybackUrl));
  await _controller.initialize();
  _controller.play();
}

// Stop server when not playing to save resources
void disposeVideo() {
  HlsDownloader.instance.stopLocalServer();
}
```

---

## License

This package is licensed under the MIT License. See [LICENSE](LICENSE) for details.
