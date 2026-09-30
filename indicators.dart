/// EMA clasica: semilla = SMA de las primeras [period] velas. Antes de eso, NaN.
List<double> emaSeries(List<double> v, int period) {
  final out = List<double>.filled(v.length, double.nan);
  if (v.length < period) return out;
  double sum = 0;
  for (var i = 0; i < period; i++) {
    sum += v[i];
  }
  var e = sum / period;
  out[period - 1] = e;
  final k = 2 / (period + 1);
  for (var i = period; i < v.length; i++) {
    e = v[i] * k + e * (1 - k);
    out[i] = e;
  }
  return out;
}
