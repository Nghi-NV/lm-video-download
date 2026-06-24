import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Server HTTP cục bộ siêu nhẹ để phục vụ việc phát HLS offline trên các thiết bị di động (đặc biệt là iOS).
class HlsLocalServer {
  HttpServer? _server;
  final String baseDir;
  int _port = 0;

  HlsLocalServer({required this.baseDir});

  /// Lấy port hiện tại của Server (0 nếu chưa khởi chạy).
  int get port => _port;

  /// Lấy trạng thái hoạt động của Server.
  bool get isRunning => _server != null;

  /// Khởi chạy Server cục bộ.
  /// Nếu [port] = 0, hệ thống tự động gán một port trống ngẫu nhiên.
  Future<int> start({int port = 0}) async {
    if (isRunning) return _port;

    try {
      // Bind với địa chỉ Loopback (127.0.0.1) để đảm bảo an toàn, chỉ truy cập trong thiết bị
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _port = _server!.port;

      if (kDebugMode) {
        print('HlsLocalServer: Đang chạy tại http://127.0.0.1:$_port');
      }

      _server!.listen(
        _handleRequest,
        onError: (error) {
          if (kDebugMode) {
            print('HlsLocalServer Error: $error');
          }
        },
      );

      return _port;
    } catch (e) {
      if (kDebugMode) {
        print('HlsLocalServer Start Exception: $e');
      }
      rethrow;
    }
  }

  /// Dừng Server cục bộ.
  Future<void> stop() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
      _port = 0;
      if (kDebugMode) {
        print('HlsLocalServer: Đã dừng.');
      }
    }
  }

  /// Xử lý các request HTTP gửi đến.
  Future<void> _handleRequest(HttpRequest request) async {
    // Chỉ chấp nhận GET requests
    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }

    // Lấy path tương đối và chuẩn hóa để tránh lỗi bảo mật directory traversal (truy cập file ngoài baseDir)
    final requestPath = Uri.decodeComponent(request.uri.path);
    final safePath = p.normalize(requestPath).replaceAll(RegExp(r'\.\./'), '');
    final filePath = p.join(
        baseDir, safePath.startsWith('/') ? safePath.substring(1) : safePath);

    final file = File(filePath);

    // Kiểm tra bảo mật Directory Traversal để đảm bảo tệp nằm trong thư mục gốc được phép
    final absoluteBase = Directory(baseDir).absolute.path;
    final absoluteFile = file.absolute.path;
    if (!p.isWithin(absoluteBase, absoluteFile) && absoluteFile != absoluteBase) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.write('Access Denied');
      await request.response.close();
      return;
    }

    // Thiết lập CORS Headers để tránh lỗi Cross-Origin trên Web/Player
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers
        .add('Access-Control-Allow-Methods', 'GET, OPTIONS');
    request.response.headers.add('Access-Control-Allow-Headers',
        'Origin, X-Requested-With, Content-Type, Accept');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    if (await file.exists()) {
      try {
        final contentType = _getMimeType(filePath);
        request.response.headers.contentType = contentType;

        // Stream tệp tin trả về client
        await file.openRead().pipe(request.response);
      } catch (e) {
        if (kDebugMode) {
          print('Error streaming file: $filePath, error: $e');
        }
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('Internal Server Error: $e');
        await request.response.close();
      }
    } else {
      if (kDebugMode) {
        print('File not found: $filePath');
      }
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('File Not Found');
      await request.response.close();
    }
  }

  /// Trả về MIME Type tương ứng cho HLS video.
  ContentType _getMimeType(String filePath) {
    final extension = p.extension(filePath).toLowerCase();
    switch (extension) {
      case '.m3u8':
        // HLS playlist MIME type chuẩn
        return ContentType('application', 'x-mpegURL', charset: 'utf-8');
      case '.ts':
        // MPEG-2 Transport Stream
        return ContentType('video', 'mp2t');
      case '.mp4':
        return ContentType('video', 'mp4');
      case '.key':
        return ContentType('application', 'octet-stream');
      default:
        return ContentType.binary;
    }
  }

  /// Tạo URL để phát lại cho tệp video cụ thể.
  String getPlaybackUrl(String relativePath) {
    if (!isRunning) return '';
    final cleanPath =
        relativePath.startsWith('/') ? relativePath : '/$relativePath';
    return 'http://127.0.0.1:$_port$cleanPath';
  }
}
