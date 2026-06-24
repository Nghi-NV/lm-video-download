import 'dart:io';
import 'dart:isolate';
import 'ts_remuxer.dart';

/// Remux một tệp MPEG-TS sang MP4 trên nền tảng native.
///
/// Toàn bộ công việc nặng (parse TS + mux MP4) chạy trong một [Isolate] riêng
/// thông qua [Isolate.run] để KHÔNG chặn luồng UI.
Future<void> remuxTsFileToMp4(String inputPath, String outputPath) async {
  await Isolate.run(() {
    final ts = File(inputPath).readAsBytesSync();
    final mp4 = remuxTsToMp4(ts);
    File(outputPath).writeAsBytesSync(mp4);
  });
}
