// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_video_download/lm_video_download.dart';

void main() {
  // Đảm bảo Flutter Binding được thiết lập cho môi trường test
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Apple BipBop HLS download integration test', () async {
    // Cho phép thực hiện kết nối mạng thật trong môi trường flutter test
    HttpOverrides.global = null;

    // Giả lập path_provider trong môi trường kiểm thử
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        return './test_download_output_standard/temp'; // Trả về thư mục tạm cục bộ
      },
    );

    print('=== BẮT ĐẦU KIỂM CHỨNG TẢI VIDEO HLS THỰC TẾ ===');

    // Link HLS test chuẩn của Apple (BipBop)
    const m3u8Url =
        'https://playertest.longtailvideo.com/adaptive/bipbop/gear1/prog_index.m3u8';

    // Thư mục lưu kết quả test cục bộ
    final outputDir = Directory('./test_download_output_standard');
    if (await outputDir.exists()) {
      await outputDir.delete(recursive: true);
    }
    await outputDir.create(recursive: true);

    print('Khởi tạo Downloader...');
    await HlsDownloader.instance.initialize(
      customStoragePath: outputDir.absolute.path,
      maxConcurrentDownloads: 5, // Tải song song 5 luồng
      enableLogging: true,
    );

    print('Đang tạo tác vụ tải từ URL: $m3u8Url');
    final task = await HlsDownloader.instance.createDownload(
      taskId: 'bipbop_test',
      m3u8Url: m3u8Url,
      fileName: 'bipbop_output.mp4',
      downloadMode: HlsDownloadMode.mergeAsSingleFile,
    );

    // Lắng nghe tiến độ
    task.progressStream.listen((progress) {
      print('Tiến độ: ${progress.percentage.toStringAsFixed(1)}% '
          '(${progress.downloadedSegments}/${progress.totalSegments} segments) '
          '- Tốc độ: ${progress.downloadSpeedKbps.toStringAsFixed(1)} KB/s');
    });

    // Lắng nghe trạng thái
    task.stateStream.listen((state) {
      print('>>> Trạng thái chuyển sang: $state');
    });

    print('Bắt đầu tải thực tế...');
    final stopwatch = Stopwatch()..start();
    await task.start();
    stopwatch.stop();

    print('\n=== KẾT QUẢ KIỂM CHỨNG ===');
    print('Thời gian tải: ${stopwatch.elapsed.inSeconds} giây');

    // Kiểm định kết quả
    final outputFile = File('${outputDir.path}/bipbop_output.mp4');
    expect(await outputFile.exists(), isTrue);

    final length = await outputFile.length();
    print('Tệp tin video tải về thành công: ${outputFile.path}');
    print('Kích thước: ${(length / (1024 * 1024)).toStringAsFixed(2)} MB');
    expect(length, greaterThan(0));

    // Dọn dẹp sau khi kiểm tra xong
    await task.delete();
    if (await outputDir.exists()) {
      await outputDir.delete(recursive: true);
    }

    print('=== KIỂM CHỨNG HOÀN TẤT THÀNH CÔNG ===');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
