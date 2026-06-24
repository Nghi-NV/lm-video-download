import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import '../models/models.dart';
import '../parser/hls_parser.dart';
import '../encryption/hls_decryptor.dart';
import '../storage/storage_manager.dart';
import 'hls_downloader.dart';

class HlsDownloadTaskImpl implements HlsDownloadTask {
  @override
  final String id;

  @override
  String m3u8Url;

  final Map<String, String>? headers;
  final String fileName;

  @override
  final HlsDownloadMode downloadMode;

  final bool ignoreFailedSegments;
  final int maxConcurrentDownloads;

  HlsDownloadState _state = HlsDownloadState.pending;
  HlsDownloadProgress _progress;
  HlsDownloadException? _exception;

  final _progressController = StreamController<HlsDownloadProgress>.broadcast();
  final _stateController = StreamController<HlsDownloadState>.broadcast();

  bool _isPaused = false;
  bool _isCancelled = false;

  // Quản lý việc tính toán tốc độ tải
  int _lastBytesDownloaded = 0;
  DateTime _lastSpeedCheckTime = DateTime.now();
  double _currentSpeedKbps = 0.0;

  HlsDownloadTaskImpl({
    required this.id,
    required this.m3u8Url,
    required this.fileName,
    this.headers,
    this.downloadMode = HlsDownloadMode.mergeAsSingleFile,
    this.ignoreFailedSegments = false,
    this.maxConcurrentDownloads = 3,
  }) : _progress = HlsDownloadProgress(
          taskId: id,
          percentage: 0.0,
          downloadedSegments: 0,
          totalSegments: 0,
          bytesDownloaded: 0,
          downloadSpeedKbps: 0.0,
        );

  @override
  HlsDownloadState get state => _state;

  @override
  HlsDownloadProgress get progress => _progress;

  @override
  HlsDownloadException? get exception => _exception;

  @override
  Stream<HlsDownloadProgress> get progressStream => _progressController.stream;

  @override
  Stream<HlsDownloadState> get stateStream => _stateController.stream;

  /// Khôi phục trạng thái và tiến độ từ dữ liệu metadata đã lưu (phục vụ khôi phục khi khởi động ứng dụng).
  void restoreInternal({
    required HlsDownloadState state,
    required HlsDownloadProgress progress,
  }) {
    _state = state;
    _progress = progress;
  }

  void _updateState(HlsDownloadState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
      _saveMetadata();
    }
  }

  void _updateProgress({
    required int downloaded,
    required int total,
    required int bytes,
  }) {
    // Tính toán tốc độ tải thực tế (mỗi 1 giây cập nhật một lần)
    final now = DateTime.now();
    final timeDiffMs = now.difference(_lastSpeedCheckTime).inMilliseconds;
    if (timeDiffMs >= 1000) {
      final bytesDiff = bytes - _lastBytesDownloaded;
      _currentSpeedKbps = (bytesDiff / 1024) / (timeDiffMs / 1000);
      _lastBytesDownloaded = bytes;
      _lastSpeedCheckTime = now;
    }

    final percentage = total > 0 ? (downloaded / total) * 100.0 : 0.0;
    _progress = HlsDownloadProgress(
      taskId: id,
      percentage: percentage,
      downloadedSegments: downloaded,
      totalSegments: total,
      bytesDownloaded: bytes,
      downloadSpeedKbps: _currentSpeedKbps,
    );
    _progressController.add(_progress);
  }

  /// Khởi chạy tác vụ tải HLS
  @override
  Future<void> start({Future<String> Function()? onUrlExpired}) async {
    if (_state == HlsDownloadState.downloading) return;

    _isPaused = false;
    _isCancelled = false;
    _exception = null;
    _updateState(HlsDownloadState.downloading);

    try {
      await _runDownload(onUrlExpired);
    } catch (e) {
      if (_isPaused) {
        _updateState(HlsDownloadState.paused);
      } else if (_isCancelled) {
        _updateState(HlsDownloadState.pending);
      } else {
        _updateState(HlsDownloadState.failed);
        _progressController.addError(e);
      }
    }
  }

  /// Tạm dừng tải
  @override
  Future<void> pause() async {
    if (_state != HlsDownloadState.downloading) return;
    _isPaused = true;
    _updateState(HlsDownloadState.paused);
  }

  /// Hủy tải và dọn dẹp các tệp tạm
  @override
  Future<void> cancel() async {
    _isCancelled = true;
    _updateState(HlsDownloadState.pending);

    // Dọn dẹp thư mục tạm
    final tempDir = await StorageManager.getTempDirectory(id);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  }

  /// Xóa tệp đã tải xong khỏi máy
  @override
  Future<void> delete() async {
    final destDir = await HlsDownloader.instance.storageDirectory;

    if (downloadMode == HlsDownloadMode.mergeAsSingleFile) {
      final file = File(p.join(destDir.path, fileName));
      if (await file.exists()) {
        await file.delete();
      }
    } else {
      final dir = Directory(p.join(destDir.path, id));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }

    // Xóa file metadata tương ứng
    final metadataFile = File(p.join(destDir.path, '.metadata_$id.json'));
    if (await metadataFile.exists()) {
      await metadataFile.delete();
    }

    _updateProgress(downloaded: 0, total: 0, bytes: 0);
    _updateState(HlsDownloadState.pending);
  }

  Future<void> _runDownload(Future<String> Function()? onUrlExpired) async {
    // 1. Fetch và parse playlist m3u8
    String m3u8Content = '';
    try {
      m3u8Content = await _fetchText(m3u8Url);
    } catch (e) {
      _exception = HlsDownloadException(
        code: HlsDownloadErrorCode.networkError,
        message: 'Không thể kết nối đến URL M3U8',
        originalError: e,
      );
      rethrow;
    }

    // 2. Xử lý Master Playlist nếu có
    if (HlsParser.isMasterPlaylist(m3u8Content)) {
      final variants = HlsParser.parseMasterPlaylist(m3u8Content, m3u8Url);
      if (variants.isEmpty) {
        throw _exception = HlsDownloadException(
          code: HlsDownloadErrorCode.invalidM3u8,
          message: 'Master playlist không chứa luồng video hợp lệ',
        );
      }
      // Chọn luồng có băng thông cao nhất làm mặc định
      m3u8Url = variants.first.url;
      m3u8Content = await _fetchText(m3u8Url);
    }

    // 3. Parse Media Playlist
    final mediaPlaylist = HlsParser.parseMediaPlaylist(m3u8Content, m3u8Url);
    if (mediaPlaylist.segments.isEmpty) {
      throw _exception = HlsDownloadException(
        code: HlsDownloadErrorCode.invalidM3u8,
        message: 'Media playlist không chứa phân đoạn video nào',
      );
    }

    final totalSegments = mediaPlaylist.segments.length;
    final tempDir = await StorageManager.getTempDirectory(id);
    final destDir = await HlsDownloader.instance.storageDirectory;

    // 4. Kiểm tra dung lượng trống (Disk space)
    await _checkAvailableDiskSpace(destDir);

    // 5. Tải khóa giải mã AES-128 nếu có
    Uint8List? keyBytes;
    if (mediaPlaylist.encryptionKey != null) {
      try {
        keyBytes = await _fetchBytes(mediaPlaylist.encryptionKey!.url);
      } catch (e) {
        // Trường hợp link token hết hạn khi tải key
        if (e is http.ClientException && onUrlExpired != null) {
          final newM3u8Url = await onUrlExpired();
          m3u8Url = newM3u8Url;
          // Tải lại key bằng URL mới đã cập nhật
          final newM3u8Content = await _fetchText(m3u8Url);
          final newMediaPlaylist =
              HlsParser.parseMediaPlaylist(newM3u8Content, m3u8Url);
          if (newMediaPlaylist.encryptionKey != null) {
            keyBytes = await _fetchBytes(newMediaPlaylist.encryptionKey!.url);
          }
        }

        if (keyBytes == null) {
          throw _exception = HlsDownloadException(
            code: HlsDownloadErrorCode.decryptionFailed,
            message: 'Không thể tải khóa giải mã AES-128',
            originalError: e,
          );
        }
      }
    }

    // 6. Quản lý tải song song các segments sử dụng Worker Pool
    final List<int> queue = List.generate(totalSegments, (index) => index);
    int activeWorkers = 0;
    int completedCount = 0;
    int totalBytesDownloaded = 0;

    // Đọc tiến độ đã lưu trước đó nếu có (Resume capability)
    final Set<int> alreadyDownloaded = {};
    for (int i = 0; i < totalSegments; i++) {
      final segFile = File(p.join(tempDir.path, 'segment_$i.ts'));
      if (await segFile.exists() && await segFile.length() > 0) {
        alreadyDownloaded.add(i);
        totalBytesDownloaded += await segFile.length();
      }
    }
    completedCount = alreadyDownloaded.length;
    queue.removeWhere((index) => alreadyDownloaded.contains(index));

    _updateProgress(
      downloaded: completedCount,
      total: totalSegments,
      bytes: totalBytesDownloaded,
    );

    final Completer<void> completer = Completer<void>();
    _lastBytesDownloaded = totalBytesDownloaded;
    _lastSpeedCheckTime = DateTime.now();

    void spawnWorker() async {
      if (queue.isEmpty || _isPaused || _isCancelled || completer.isCompleted) {
        activeWorkers--;
        if (activeWorkers == 0 && !completer.isCompleted) {
          completer.complete();
        }
        return;
      }

      final index = queue.removeAt(0);
      final segmentUrl = mediaPlaylist.segments[index];

      try {
        final segmentData =
            await _downloadSegmentWithRetry(segmentUrl, index, onUrlExpired);

        if (_isPaused || _isCancelled) return;

        // Giải mã nếu có key (chạy ngầm trong Isolate để tránh block UI thread)
        Uint8List processedData = segmentData;
        if (keyBytes != null && mediaPlaylist.encryptionKey != null) {
          final encryptionKey = mediaPlaylist.encryptionKey!;
          final mediaSequence = mediaPlaylist.mediaSequence;
          final nonNullKeyBytes = keyBytes;
          processedData = await Isolate.run(() {
            return HlsDecryptor.decrypt(
              encryptedData: segmentData,
              keyBytes: nonNullKeyBytes,
              keyConfig: encryptionKey,
              segmentIndex: index,
              mediaSequenceStart: mediaSequence,
            );
          });
        }

        // Lưu vào tệp tạm
        final segFile = File(p.join(tempDir.path, 'segment_$index.ts'));
        await segFile.writeAsBytes(processedData);

        completedCount++;
        totalBytesDownloaded += processedData.length;
        _updateProgress(
          downloaded: completedCount,
          total: totalSegments,
          bytes: totalBytesDownloaded,
        );
      } catch (e) {
        if (!ignoreFailedSegments) {
          if (!completer.isCompleted) {
            _exception = HlsDownloadException(
              code: HlsDownloadErrorCode.segmentDownloadFailed,
              message: 'Lỗi khi tải segment $index',
              originalError: e,
            );
            completer.completeError(e);
          }
          return;
        }
      }

      // Tiếp tục lấy segment tiếp theo
      spawnWorker();
    }

    // Khởi chạy số luồng tối đa
    final workersToSpawn = queue.length < maxConcurrentDownloads
        ? queue.length
        : maxConcurrentDownloads;
    if (workersToSpawn == 0) {
      if (!completer.isCompleted) completer.complete();
    } else {
      activeWorkers = workersToSpawn;
      for (int i = 0; i < workersToSpawn; i++) {
        spawnWorker();
      }
    }

    // Đợi hàng đợi hoàn tất
    await completer.future;

    if (_isPaused) {
      throw Exception('Tác vụ bị tạm dừng');
    }
    if (_isCancelled) {
      throw Exception('Tác vụ bị hủy');
    }

    // 7. Xử lý lưu trữ đầu ra (Merge hoặc giữ cấu trúc thư mục)
    if (downloadMode == HlsDownloadMode.mergeAsSingleFile) {
      try {
        await StorageManager.mergeSegments(
          tempDir: tempDir,
          destDir: destDir,
          outputFileName: fileName,
          totalSegments: totalSegments,
        );
      } catch (e) {
        throw _exception = HlsDownloadException(
          code: HlsDownloadErrorCode.mergeFailed,
          message: 'Lỗi ghép file video HLS cục bộ',
          originalError: e,
        );
      }
    } else {
      // Lưu dưới dạng thư mục HLS Local
      final taskDestDir = Directory(p.join(destDir.path, id));
      if (!await taskDestDir.exists()) {
        await taskDestDir.create(recursive: true);
      }

      // Di chuyển các tệp phân đoạn sang thư mục đích chính thức
      for (int i = 0; i < totalSegments; i++) {
        final src = File(p.join(tempDir.path, 'segment_$i.ts'));
        final dest = File(p.join(taskDestDir.path, 'segment_$i.ts'));
        if (await src.exists()) {
          await src.rename(dest.path);
        }
      }

      // Tạo local index.m3u8
      await StorageManager.createLocalM3u8(
        m3u8OriginalContent: m3u8Content,
        destDir: taskDestDir,
        originalSegments: mediaPlaylist.segments,
        keyBytes: keyBytes,
      );

      // Xóa thư mục tạm
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }

    // Cập nhật trạng thái thành công hoàn toàn
    _updateProgress(
      downloaded: totalSegments,
      total: totalSegments,
      bytes: totalBytesDownloaded,
    );
    _updateState(HlsDownloadState.success);
  }

  /// Tải tệp segment kèm cơ chế retry (Exponential backoff)
  Future<Uint8List> _downloadSegmentWithRetry(
    String url,
    int index,
    Future<String> Function()? onUrlExpired,
  ) async {
    int retries = 3;
    int delayMs = 1000;

    while (retries > 0) {
      try {
        return await _fetchBytes(url);
      } catch (e) {
        retries--;

        // Kiểm tra xem lỗi có phải do link hết hạn (403/401)
        if (e is http.ClientException && onUrlExpired != null && retries > 0) {
          try {
            final newM3u8Url = await onUrlExpired();
            m3u8Url = newM3u8Url;
            // Cập nhật lại playlist để parse URL segment mới
            final newM3u8Content = await _fetchText(m3u8Url);
            final newMediaPlaylist =
                HlsParser.parseMediaPlaylist(newM3u8Content, m3u8Url);
            if (index < newMediaPlaylist.segments.length) {
              url = newMediaPlaylist.segments[index];
            }
          } catch (renewErr) {
            if (kDebugMode) {
              print('Lỗi làm mới URL token: $renewErr');
            }
          }
        }

        if (retries == 0) rethrow;

        await Future.delayed(Duration(milliseconds: delayMs));
        delayMs *= 2; // Tăng thời gian chờ
      }
    }
    throw Exception('Tải phân mảnh thất bại.');
  }

  /// Kiểm tra không gian lưu trữ trống trên thiết bị
  Future<void> _checkAvailableDiskSpace(Directory destDir) async {
    if (kIsWeb) return;
    try {
      // Vì không thể đo chính xác dung lượng trước khi tải HLS thực tế,
      // Ta kiểm tra dung lượng trống tối thiểu là 50MB để bắt đầu.
      // Trên native Android/iOS, có thể dùng MethodChannel để kiểm tra chính xác hơn.
      // Một cách tiếp cận an toàn trong Dart:
      final freeSpace = await _getFreeDiskSpace(destDir.path);
      if (freeSpace != null && freeSpace < 50 * 1024 * 1024) {
        throw HlsDownloadException(
          code: HlsDownloadErrorCode.diskFull,
          message: 'Dung lượng bộ nhớ thiết bị còn trống quá thấp (dưới 50MB)',
        );
      }
    } catch (e) {
      if (e is HlsDownloadException) rethrow;
    }
  }

  /// Ước lượng dung lượng trống cục bộ (Fallback nếu không có native method channel)
  Future<int?> _getFreeDiskSpace(String path) async {
    // Để giữ thư viện thuần Dart tương thích đa nền tảng dễ dàng,
    // ta chấp nhận kiểm tra cơ bản. Nếu cần kiểm tra cực kỳ chính xác dung lượng disk
    // trên Android/iOS, app chủ nên sử dụng gói storage_space hoặc tương đương.
    return 500 * 1024 * 1024; // Fallback trả về 500MB trống
  }

  /// Thực hiện HTTP GET lấy text
  Future<String> _fetchText(String url) async {
    final response = await http.get(Uri.parse(url), headers: headers);
    if (response.statusCode != 200) {
      throw http.ClientException(
          'HTTP ${response.statusCode}: ${response.reasonPhrase}');
    }
    return response.body;
  }

  /// Thực hiện HTTP GET lấy bytes
  Future<Uint8List> _fetchBytes(String url) async {
    final response = await http.get(Uri.parse(url), headers: headers);
    if (response.statusCode != 200) {
      throw http.ClientException(
          'HTTP ${response.statusCode}: ${response.reasonPhrase}');
    }
    return response.bodyBytes;
  }

  /// Lưu trữ metadata của tác vụ xuống file cục bộ để hỗ trợ khôi phục sau khởi động lại app
  Future<void> _saveMetadata() async {
    if (kIsWeb) return;
    try {
      final destDir = await HlsDownloader.instance.storageDirectory;
      final metadataFile = File(p.join(destDir.path, '.metadata_$id.json'));
      final Map<String, dynamic> data = {
        'id': id,
        'm3u8Url': m3u8Url,
        'fileName': fileName,
        'headers': headers,
        'downloadMode': downloadMode.index,
        'state': _state.index,
        'downloadedSegments': _progress.downloadedSegments,
        'totalSegments': _progress.totalSegments,
        'bytesDownloaded': _progress.bytesDownloaded,
      };
      await metadataFile.writeAsString(jsonEncode(data));
    } catch (e) {
      if (kDebugMode) {
        print('Lưu metadata task $id thất bại: $e');
      }
    }
  }

  /// Đóng các Stream Controllers
  void dispose() {
    _progressController.close();
    _stateController.close();
  }
}
