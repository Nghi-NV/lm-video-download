## 1.0.0

* Initial stable release.
* Pure-Dart MPEG-TS → MP4 remuxer (H.264/AVC + H.265/HEVC video, AAC audio). No
  native code, no FFI/WASM, no ffmpeg — works on Android, iOS, macOS, Windows and Web.
  Builds correct avcC/hvcC (SPS/PPS/VPS), interleaved A/V, faststart moov, and full
  sample tables so the output `.mp4` is playable everywhere.
* Remux runs in a background `Isolate` so it never blocks the UI thread.
* Added pure Dart HLS parser supporting Master and Media M3U8 playlists.
* Implemented core downloader engine with parallel segments downloads using a worker pool.
* Integrated AES-128-CBC decryption support for encrypted HLS streams.
* Added StorageManager to manage local directories and merge segment files (.ts) into a single file or keep them in structured folders.
* Added custom local HTTP Server (HlsLocalServer) to stream HLS offline over localhost for diplay/playback (specifically addressing AVPlayer restrictions on iOS).
* Implemented progress reporting (percentage, downloaded/total segments, speed).
* Added retry mechanism for segment downloads and token expiration renew callback.
* Supported persistent task state metadata to automatically resume unfinished downloads.
