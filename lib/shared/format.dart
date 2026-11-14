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

/// Fecha ISO-8601 -> "2026-01-31" (primeros 10 caracteres).
String formatIsoDate(String iso) =>
    iso.length >= 10 ? iso.substring(0, 10) : iso;
