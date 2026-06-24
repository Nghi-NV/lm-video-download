import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../remuxer/remuxer_io.dart';

/// Quản lý việc lưu trữ tệp, tạo thư mục tạm và ghép phân đoạn video.
class StorageManager {
  /// Lấy thư mục tải xuống phù hợp với từng nền tảng.
  static Future<Directory> getDownloadDirectory({String? customPath}) async {
    Directory resolvedDir;

    if (customPath != null && customPath.isNotEmpty) {
      resolvedDir = Directory(customPath);
    } else if (kIsWeb) {
      throw UnsupportedError(
          'Lưu trữ trực tiếp thư mục không hỗ trợ trên nền tảng Web');
    } else if (Platform.isAndroid) {
      final dirs =
          await getExternalStorageDirectories(type: StorageDirectory.downloads);
      resolvedDir = (dirs != null && dirs.isNotEmpty)
          ? dirs.first
          : await getApplicationDocumentsDirectory();
    } else if (Platform.isIOS) {
      resolvedDir = await getApplicationDocumentsDirectory();
    } else if (Platform.isMacOS || Platform.isWindows) {
      final downloadsDir = await getDownloadsDirectory();
      resolvedDir = downloadsDir ?? await getApplicationDocumentsDirectory();
    } else {
      resolvedDir = await getApplicationDocumentsDirectory();
    }

    if (!await resolvedDir.exists()) {
      await resolvedDir.create(recursive: true);
    }
    return resolvedDir;
  }

  /// Lấy thư mục tạm để lưu các phân mảnh (.ts) trong lúc đang tải.
  static Future<Directory> getTempDirectory(String taskId) async {
    final tempDir = await getTemporaryDirectory();
    final taskTempDir = Directory(p.join(tempDir.path, 'hls_download', taskId));
    if (!await taskTempDir.exists()) {
      await taskTempDir.create(recursive: true);
    }
    return taskTempDir;
  }

  /// Ghép tất cả các tệp segment thành một file duy nhất (.ts), và remux sang MP4 nếu được chỉ định.
  static Future<File> mergeSegments({
    required Directory tempDir,
    required Directory destDir,
    required String outputFileName,
    required int totalSegments,
  }) async {
    final outputFile = File(p.join(destDir.path, outputFileName));
    final isMp4 = p.extension(outputFileName).toLowerCase() == '.mp4';

    final File intermediateFile;
    if (isMp4) {
      intermediateFile = File(p.join(tempDir.path, 'merged_temp.ts'));
    } else {
      intermediateFile = outputFile;
    }

    // Nếu tệp trung gian đã tồn tại, xóa đi để tạo mới
    if (await intermediateFile.exists()) {
      await intermediateFile.delete();
    }

    // Mở file write stream để ghi liên tục
    final IOSink sink = intermediateFile.openWrite(mode: FileMode.write);

    try {
      for (int i = 0; i < totalSegments; i++) {
        final segmentFile = File(p.join(tempDir.path, 'segment_$i.ts'));
        if (!await segmentFile.exists()) {
          throw Exception(
              'Không tìm thấy tệp phân đoạn để ghép: segment_$i.ts');
        }

        // Đọc và ghi bytes của segment vào file tổng
        final bytes = await segmentFile.readAsBytes();
        sink.add(bytes);
      }

      // Flush và đóng stream
      await sink.flush();
      await sink.close();

      if (isMp4) {
        // Remux MPEG-TS -> MP4 bằng Dart thuần, chạy trong Isolate riêng để
        // không chặn luồng UI.
        if (await outputFile.exists()) {
          await outputFile.delete();
        }

        try {
          await remuxTsFileToMp4(
            intermediateFile.absolute.path,
            outputFile.absolute.path,
          );
        } finally {
          // Xóa tệp TS trung gian dù thành công hay thất bại.
          if (await intermediateFile.exists()) {
            await intermediateFile.delete();
          }
        }
      }

      // Xóa thư mục tạm thời sau khi ghép thành công
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }

      return outputFile;
    } catch (e) {
      await sink.close();
      if (await intermediateFile.exists() && isMp4) {
        await intermediateFile.delete();
      }
      if (await outputFile.exists()) {
        await outputFile.delete();
      }
      throw Exception('Lỗi trong quá trình ghép phân mảnh video: $e');
    }
  }

  /// Lưu cấu trúc thư mục chứa m3u8 cục bộ và các segment tương ứng.
  static Future<File> createLocalM3u8({
    required String m3u8OriginalContent,
    required Directory destDir,
    required List<String> originalSegments,
    Uint8List? keyBytes,
  }) async {
    final lines = m3u8OriginalContent.split('\n');
    final List<String> localLines = [];
    int segmentIndex = 0;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXT-X-KEY:')) {
        // Nếu có mã hóa, nếu ta lưu key cục bộ:
        if (keyBytes != null) {
          final keyFile = File(p.join(destDir.path, 'key.key'));
          await keyFile.writeAsBytes(keyBytes);
          // Sửa URI trỏ về file key.key cục bộ
          // Ví dụ: #EXT-X-KEY:METHOD=AES-128,URI="key.key"
          // Ta cần parse và thay thế URI bằng đường dẫn tương đối
          final cleanLine =
              line.replaceAll(RegExp(r'URI="[^"]*"'), 'URI="key.key"');
          localLines.add(cleanLine);
        } else {
          localLines.add(line);
        }
      } else if (!line.startsWith('#')) {
        // Đây là URL của segment, sửa thành tên file cục bộ tương đối
        localLines.add('segment_$segmentIndex.ts');
        segmentIndex++;
      } else {
        localLines.add(line);
      }
    }

    final localM3u8File = File(p.join(destDir.path, 'index.m3u8'));
    await localM3u8File.writeAsString(localLines.join('\n'));
    return localM3u8File;
  }
}
