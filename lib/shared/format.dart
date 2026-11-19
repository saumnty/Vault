/// Tamaño legible: "532 B", "1,5 KB", "12,40 MB".
String formatBytes(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  String fmt(double v, int decimals) =>
      v.toStringAsFixed(decimals).replaceAll('.', ',');
  if (bytes < kb) return '$bytes B';
  if (bytes < mb) return '${fmt(bytes / kb, 1)} KB';
  if (bytes < gb) return '${fmt(bytes / mb, 2)} MB';
  return '${fmt(bytes / gb, 2)} GB';
}

/// Duración de video: "0:08", "12:05", "1:02:09".
String formatVideoDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// Fecha ISO-8601 -> "2026-01-31" (primeros 10 caracteres).
String formatIsoDate(String iso) =>
    iso.length >= 10 ? iso.substring(0, 10) : iso;
