import 'dart:async';

/// Trạng thái của tác vụ tải video.
enum HlsDownloadState {
  pending, // Đang chờ trong hàng đợi
  downloading, // Đang tải
  paused, // Đang tạm dừng
  success, // Tải thành công hoàn toàn
  failed, // Thất bại
}

/// Chế độ tải video HLS.
enum HlsDownloadMode {
  /// Ghép tất cả các tệp phân đoạn (.ts) thành một tệp duy nhất.
  mergeAsSingleFile,

  /// Giữ nguyên cấu trúc thư mục chứa các tệp phân đoạn và tệp m3u8 cục bộ.
  keepFolderStructure,
}

/// Thông tin chi tiết về tiến trình tải xuống.
class HlsDownloadProgress {
  final String taskId;
  final double percentage; // Tiến trình tải tính theo % (0.0 đến 100.0)
  final int downloadedSegments; // Số phân đoạn đã tải thành công
  final int totalSegments; // Tổng số phân đoạn
  final int bytesDownloaded; // Tổng dung lượng đã tải (bytes)
  final double downloadSpeedKbps; // Tốc độ tải hiện tại (KB/s)

  HlsDownloadProgress({
    required this.taskId,
    required this.percentage,
    required this.downloadedSegments,
    required this.totalSegments,
    required this.bytesDownloaded,
    required this.downloadSpeedKbps,
  });

  @override
  String toString() {
    return 'HlsDownloadProgress(taskId: $taskId, progress: ${percentage.toStringAsFixed(1)}%, segments: $downloadedSegments/$totalSegments, bytes: ${(bytesDownloaded / (1024 * 1024)).toStringAsFixed(2)} MB, speed: ${downloadSpeedKbps.toStringAsFixed(1)} KB/s)';
  }
}

/// Các mã lỗi chi tiết khi thực hiện tải.
enum HlsDownloadErrorCode {
  networkError, // Lỗi kết nối internet
  diskFull, // Bộ nhớ thiết bị đầy
  permissionDenied, // Chưa cấp quyền lưu trữ
  invalidM3u8, // File m3u8 không hợp lệ hoặc không parse được
  segmentDownloadFailed, // Lỗi tải một phân đoạn cụ thể sau nhiều lần retry
  decryptionFailed, // Lỗi giải mã AES-128
  mergeFailed, // Lỗi ghép các segment thành file video hoàn chỉnh
  unknown, // Lỗi không xác định
}

/// Ngoại lệ chi tiết trong quá trình tải.
class HlsDownloadException implements Exception {
  final HlsDownloadErrorCode code;
  final String message;
  final dynamic originalError;

  HlsDownloadException({
    required this.code,
    required this.message,
    this.originalError,
  });

  @override
  String toString() =>
      'HlsDownloadException[$code]: $message (Original: $originalError)';
}

/// Lớp mô tả một biến thể phân giải (Variant stream) trong Master Playlist.
class HlsVariantStream {
  final String url;
  final int? bandwidth;
  final String? resolution;
  final String? codecs;

  HlsVariantStream({
    required this.url,
    this.bandwidth,
    this.resolution,
    this.codecs,
  });

  @override
  String toString() =>
      'HlsVariantStream(resolution: $resolution, bandwidth: $bandwidth, url: $url)';
}

/// Giao diện điều khiển tác vụ tải xuống.
abstract class HlsDownloadTask {
  String get id;
  String get m3u8Url;
  HlsDownloadState get state;
  HlsDownloadProgress get progress;
  HlsDownloadException? get exception;
  HlsDownloadMode get downloadMode;

  /// Stream theo dõi tiến trình tải theo thời gian thực.
  Stream<HlsDownloadProgress> get progressStream;

  /// Stream theo dõi sự thay đổi trạng thái của tác vụ.
  Stream<HlsDownloadState> get stateStream;

  /// Bắt đầu hoặc tiếp tục tải.
  Future<void> start({
    Future<String> Function()? onUrlExpired,
  });

  /// Tạm dừng tác vụ.
  Future<void> pause();

  /// Hủy tác vụ và xóa dữ liệu tạm thời.
  Future<void> cancel();

  /// Xóa file video đã tải khỏi bộ nhớ.
  Future<void> delete();
}
