import 'models.dart';

class PivotSet {
  final List<Pivot> highs;
  final List<Pivot> lows;
  const PivotSet(this.highs, this.lows);
}

/// Pivotes confirmados: la vela i es swing high si su maximo es mayor que las
/// [n] velas anteriores y >= que las [n] siguientes (todas CERRADAS).
/// Un pivote solo existe cuando ya hay [n] velas cerradas a su derecha.
PivotSet findPivots(List<Candle> c, int n) {
  final highs = <Pivot>[];
  final lows = <Pivot>[];
  for (var i = n; i < c.length - n; i++) {
    var isH = true;
    var isL = true;
    for (var j = 1; j <= n; j++) {
      if (!(c[i].high > c[i - j].high) || !(c[i].high >= c[i + j].high)) isH = false;
      if (!(c[i].low < c[i - j].low) || !(c[i].low <= c[i + j].low)) isL = false;
      if (!isH && !isL) break;
    }
    if (isH) highs.add(Pivot(i, c[i].openTime, c[i].high, true));
    if (isL) lows.add(Pivot(i, c[i].openTime, c[i].low, false));
  }
  return PivotSet(highs, lows);
}

class StructureView {
  final PivotSet p;
  final String hLabel; // HH / LH / EH / --
  final String lLabel; // HL / LL / EL / --
  const StructureView(this.p, this.hLabel, this.lLabel);

  Pivot? get lastHigh => p.highs.isEmpty ? null : p.highs.last;
  Pivot? get lastLow => p.lows.isEmpty ? null : p.lows.last;
  bool get bullish => hLabel == 'HH' && lLabel == 'HL';
  bool get bearish => hLabel == 'LH' && lLabel == 'LL';
}

StructureView analyze(List<Candle> closed, int n) {
  final p = findPivots(closed, n);
  var h = '--';
  var l = '--';
  if (p.highs.length >= 2) {
    final a = p.highs[p.highs.length - 2].price;
    final b = p.highs.last.price;
    h = b > a ? 'HH' : (b < a ? 'LH' : 'EH');
  }
  if (p.lows.length >= 2) {
    final a = p.lows[p.lows.length - 2].price;
    final b = p.lows.last.price;
    l = b > a ? 'HL' : (b < a ? 'LL' : 'EL');
  }
  return StructureView(p, h, l);
}

class BiasResult {
  final Bias bias;
  final String structure; // p.ej. "HH/HL"
  final String note;
  final String patterns; // solo informativo
  const BiasResult(this.bias, this.structure, this.note, this.patterns);
}

/// Sesgo 1H automatico. NO usa EMA50.
/// Alcista = HH + HL. Bajista = LH + LL. BOS por CIERRE 1H contra el ultimo
/// swing protegido invalida la estructura -> NEUTRAL. Sin estructura clara -> NEUTRAL.
BiasResult computeBias1h(List<Candle> h1, int n) {
  if (h1.length < n * 2 + 6) {
    return const BiasResult(Bias.neutral, '--/--', 'Insufficient 1H data', '');
  }
  final st = analyze(h1, n);
  final structure = '${st.hLabel}/${st.lLabel}';
  final patterns = _patterns(h1, st);
  final close = h1.last.close;
  if (st.bullish) {
    if (close < st.lastLow!.price) {
      return BiasResult(Bias.neutral, structure,
          '1H BOS down: close ${f2(close)} < HL ${f2(st.lastLow!.price)}', patterns);
    }
    return BiasResult(Bias.long, structure, 'HH + HL', patterns);
  }
  if (st.bearish) {
    if (close > st.lastHigh!.price) {
      return BiasResult(Bias.neutral, structure,
          '1H BOS up: close ${f2(close)} > LH ${f2(st.lastHigh!.price)}', patterns);
    }
    return BiasResult(Bias.short, structure, 'LH + LL', patterns);
  }
  return BiasResult(Bias.neutral, structure, 'No clear structure', patterns);
}

/// Doble techo/suelo y engulfing: SOLO informativos, no alteran el sesgo.
String _patterns(List<Candle> c, StructureView st) {
  final out = <String>[];
  if (st.p.highs.length >= 2) {
    final a = st.p.highs[st.p.highs.length - 2].price;
    final b = st.p.highs.last.price;
    if ((a - b).abs() / a <= 0.001) out.add('DOUBLE TOP');
  }
  if (st.p.lows.length >= 2) {
    final a = st.p.lows[st.p.lows.length - 2].price;
    final b = st.p.lows.last.price;
    if ((a - b).abs() / a <= 0.001) out.add('DOUBLE BOTTOM');
  }
  if (c.length >= 2) {
    final p = c[c.length - 2];
    final k = c.last;
    if (p.close < p.open && k.close > k.open && k.open <= p.close && k.close >= p.open) {
      out.add('BULL ENGULFING');
    }
    if (p.close > p.open && k.close < k.open && k.open >= p.close && k.close <= p.open) {
      out.add('BEAR ENGULFING');
    }
  }
  return out.join(', ');
}

class SR {
  final double? support;
  final double? resistance;
  const SR(this.support, this.resistance);
}

/// Soporte = swing mas cercano por debajo del precio; resistencia = por encima.
SR nearestSR(double price, List<double> levels) {
  double? s;
  double? r;
  for (final l in levels) {
    if (l < price && (s == null || l > s)) s = l;
    if (l > price && (r == null || l < r)) r = l;
  }
  return SR(s, r);
}
