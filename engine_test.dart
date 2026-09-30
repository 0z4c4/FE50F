import 'package:flutter_test/flutter_test.dart';
import 'package:fe50f/engine/indicators.dart';
import 'package:fe50f/engine/models.dart';
import 'package:fe50f/engine/structure.dart';

Candle c(int i, double o, double h, double l, double cl, {bool closed = true}) => Candle(
    openTime: i * 60000, open: o, high: h, low: l, close: cl, volume: 1, closed: closed);

void main() {
  test('EMA: semilla SMA y NaN previo', () {
    final e = emaSeries(List.generate(10, (i) => i + 1.0), 5);
    expect(e[3].isNaN, true);
    expect(e[4], closeTo(3.0, 1e-9)); // SMA(1..5)
    expect(e[5], closeTo(3.0 + (6 - 3.0) * 2 / 6, 1e-9));
  });

  test('CandleSeries ignora cierres duplicados y actualizaciones repetidas', () {
    final s = CandleSeries('1m', 60000);
    expect(s.apply(c(1, 1, 2, 0, 1)), true);
    expect(s.apply(c(1, 1, 2, 0, 1)), false); // duplicado
    expect(s.closed.length, 1);
    expect(s.apply(c(2, 1, 2, 0, 1, closed: false)), false); // abierta: no cuenta como cierre
    expect(s.open?.openTime, 2 * 60000);
    expect(s.apply(c(2, 1, 3, 0, 2)), true);
    expect(s.open, isNull);
  });

  test('pivotes solo se confirman con n velas cerradas a la derecha', () {
    // subida, pico en i=3, bajada
    final candles = [
      c(0, 1, 1.5, 0.9, 1.2),
      c(1, 1.2, 2.0, 1.1, 1.8),
      c(2, 1.8, 2.5, 1.7, 2.4),
      c(3, 2.4, 3.0, 2.3, 2.5),
      c(4, 2.5, 2.6, 2.0, 2.1),
      c(5, 2.1, 2.2, 1.5, 1.6),
      c(6, 1.6, 1.8, 1.2, 1.3),
    ];
    final p = findPivots(candles, 3);
    expect(p.highs.length, 1);
    expect(p.highs.first.index, 3);
    expect(findPivots(candles.sublist(0, 6), 3).highs.length, 0); // aun sin 3 a la derecha
  });

  test('sesgo 1H alcista con HH+HL y NEUTRAL sin estructura', () {
    // zig-zag ascendente
    final pts = [10, 12, 9.5, 14, 11, 16, 12.5, 18, 14, 20, 16, 22, 18.5, 24, 20.5, 25, 23.0];
    final h1 = <Candle>[];
    var i = 0;
    for (var k = 0; k < pts.length - 1; k++) {
      final a = pts[k].toDouble(), b = pts[k + 1].toDouble();
      for (var s = 0; s < 3; s++) {
        final o = a + (b - a) * s / 3, cl = a + (b - a) * (s + 1) / 3;
        h1.add(c(i++, o, o > cl ? o : cl, o > cl ? cl : o, cl));
      }
    }
    final r = computeBias1h(h1, 2);
    expect(r.structure, 'HH/HL');
    expect(r.bias, Bias.long);
    expect(computeBias1h(h1.sublist(0, 5), 2).bias, Bias.neutral);
  });

  test('nearestSR devuelve soporte y resistencia mas cercanos', () {
    final sr = nearestSR(100, [90, 95, 105, 120]);
    expect(sr.support, 95);
    expect(sr.resistance, 105);
  });
}
