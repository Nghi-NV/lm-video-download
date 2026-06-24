import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../models/models.dart';
import '../storage/storage_manager.dart';
import '../server/local_server.dart';
import 'hls_download_task_impl.dart';

/// Bộ quản lý và điều phối các tác vụ tải video HLS (Singleton).
class HlsDownloader {
  static final HlsDownloader instance = HlsDownloader._internal();
  HlsDownloader._internal();

  final Map<String, HlsDownloadTaskImpl> _tasks = {};

  String? _customStoragePath;
  int _maxConcurrentDownloads = 3;
  bool _enableLogging = true;
  bool _isInitialized = false;

  HlsLocalServer? _localServer;

  /// Lấy thư mục lưu trữ đã được cấu hình.
  Future<Directory> get storageDirectory =>
      StorageManager.getDownloadDirectory(customPath: _customStoragePath);

  /// Khởi tạo cấu hình mặc định cho Downloader và khôi phục các tác vụ trước đó.
  Future<void> initialize({
    String? customStoragePath,
    int maxConcurrentDownloads = 3,
    bool enableLogging = true,
  }) async {
    if (_isInitialized) return;

    _customStoragePath = customStoragePath;
    _maxConcurrentDownloads = maxConcurrentDownloads;
    _enableLogging = enableLogging;

    if (!kIsWeb) {
      await _restoreTasks();
    }

    _isInitialized = true;

    if (_enableLogging) {
      debugPrint('HlsDownloader: Đã khởi tạo thành công.');
    }
  }

  /// Tạo một tác vụ tải video HLS mới hoặc trả về tác vụ hiện tại nếu ID đã tồn tại.
  Future<HlsDownloadTask> createDownload({
    required String taskId,
    required String m3u8Url,
    Map<String, String>? headers,
    String? fileName,
    HlsDownloadMode downloadMode = HlsDownloadMode.mergeAsSingleFile,
    bool ignoreFailedSegments = false,
  }) async {
    _checkInitialized();

    // Sanitize taskId và fileName để tránh các lỗi bảo mật về chèn/điều hướng đường dẫn (path traversal)
    final sanitizedTaskId = taskId
        .replaceAll(RegExp(r'[/\\]'), '_')
        .replaceAll(RegExp(r'\.\.+'), '.');
    final sanitizedFileName = (fileName ?? '${sanitizedTaskId}_video.mp4')
        .replaceAll(RegExp(r'[/\\]'), '_')
        .replaceAll(RegExp(r'\.\.+'), '.');

    // Trả về tác vụ hiện tại nếu đã được đăng ký
    if (_tasks.containsKey(sanitizedTaskId)) {
      return _tasks[sanitizedTaskId]!;
    }

    final task = HlsDownloadTaskImpl(
      id: sanitizedTaskId,
      m3u8Url: m3u8Url,
      fileName: sanitizedFileName,
      headers: headers,
      downloadMode: downloadMode,
      ignoreFailedSegments: ignoreFailedSegments,
      maxConcurrentDownloads: _maxConcurrentDownloads,
    );

    _tasks[taskId] = task;

    // Ghi nhận lưu trữ metadata ban đầu
    if (!kIsWeb) {
      // Gửi ngầm lưu metadata
      // ignore: discarded_futures
      _saveInitialMetadata(task);
    }

    return task;
  }

  /// Lấy danh sách tất cả các tác vụ tải hiện có.
  Future<List<HlsDownloadTask>> getAllTasks() async {
    _checkInitialized();
    return _tasks.values.toList();
  }

  /// Tìm kiếm một tác vụ cụ thể dựa trên ID.
  Future<HlsDownloadTask?> getTask(String taskId) async {
    _checkInitialized();
    final sanitizedTaskId = taskId
        .replaceAll(RegExp(r'[/\\]'), '_')
        .replaceAll(RegExp(r'\.\.+'), '.');
    return _tasks[sanitizedTaskId];
  }

  /// Khởi động Local Web Server phục vụ việc phát HLS offline.
  /// Thư mục gốc để serve sẽ là thư mục tải xuống chính thức của app.
  Future<HlsLocalServer> startLocalServer({int port = 0}) async {
    _checkInitialized();
    if (_localServer != null && _localServer!.isRunning) {
      return _localServer!;
    }

    final destDir = await storageDirectory;
    _localServer = HlsLocalServer(baseDir: destDir.path);
    await _localServer!.start(port: port);
    return _localServer!;
  }

  /// Dừng Local Web Server.
  Future<void> stopLocalServer() async {
    if (_localServer != null) {
      await _localServer!.stop();
      _localServer = null;
    }
  }

  void _checkInitialized() {
    if (!_isInitialized) {
      throw StateError(
        'HlsDownloader chưa được khởi tạo. Vui lòng gọi HlsDownloader.instance.initialize() trước.',
      );
    }
  }

  /// Khôi phục danh sách tác vụ từ các file metadata đã lưu
  Future<void> _restoreTasks() async {
    try {
      final destDir = await StorageManager.getDownloadDirectory(
          customPath: _customStoragePath);
      if (!await destDir.exists()) return;

      final List<FileSystemEntity> files = destDir.listSync();
      for (final entity in files) {
        final name = p.basename(entity.path);
        if (entity is File &&
            name.startsWith('.metadata_') &&
            name.endsWith('.json')) {
          try {
            final content = await entity.readAsString();
            final Map<String, dynamic> data = jsonDecode(content);

            final taskId = data['id'] as String;
            final m3u8Url = data['m3u8Url'] as String;
            final fileName = data['fileName'] as String;
            final headersMap =
                (data['headers'] as Map?)?.cast<String, String>();
            final downloadModeIndex = data['downloadMode'] as int;

            final task = HlsDownloadTaskImpl(
              id: taskId,
              m3u8Url: m3u8Url,
              fileName: fileName,
              headers: headersMap,
              downloadMode: HlsDownloadMode.values[downloadModeIndex],
              maxConcurrentDownloads: _maxConcurrentDownloads,
            );

            // Gán lại trạng thái trước đó
            final stateIndex = data['state'] as int;
            final restoredState = HlsDownloadState.values[stateIndex];

            // Gán tiến độ trước đó
            final downloaded = data['downloadedSegments'] as int;
            final total = data['totalSegments'] as int;
            final bytes = data['bytesDownloaded'] as int;
            final percentage = total > 0 ? (downloaded / total) * 100.0 : 0.0;

            final restoredProgress = HlsDownloadProgress(
              taskId: taskId,
              percentage: percentage,
              downloadedSegments: downloaded,
              totalSegments: total,
              bytesDownloaded: bytes,
              downloadSpeedKbps: 0.0,
            );

            task.restoreInternal(
                state: restoredState, progress: restoredProgress);

            _tasks[taskId] = task;
          } catch (e) {
            if (_enableLogging) {
              debugPrint('Lỗi khi khôi phục task từ file ${entity.path}: $e');
            }
          }
        }
      }
    } catch (e) {
      if (_enableLogging) {
        debugPrint('Lỗi khôi phục tác vụ: $e');
      }
    }
  }

  Future<void> _saveInitialMetadata(HlsDownloadTaskImpl task) async {
    try {
      final destDir = await storageDirectory;
      final metadataFile =
          File(p.join(destDir.path, '.metadata_${task.id}.json'));
      final Map<String, dynamic> data = {
        'id': task.id,
        'm3u8Url': task.m3u8Url,
        'fileName': task.fileName,
        'headers': task.headers,
        'downloadMode': task.downloadMode.index,
        'state': task.state.index,
        'downloadedSegments': task.progress.downloadedSegments,
        'totalSegments': task.progress.totalSegments,
        'bytesDownloaded': task.progress.bytesDownloaded,
      };
      await metadataFile.writeAsString(jsonEncode(data));
    } catch (e) {
      if (_enableLogging) {
        debugPrint('Lỗi khi lưu metadata ban đầu cho task ${task.id}: $e');
      }
    }
  }
}
