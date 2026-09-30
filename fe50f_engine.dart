import 'dart:math' as math;

import 'indicators.dart';
import 'models.dart';
import 'structure.dart';

class EngineEvent {
  /// 'signal' | 'tp' | 'sl' | 'info'
  final String kind;
  final String title;
  final String body;
  const EngineEvent(this.kind, this.title, this.body);
}

class Setup {
  final String id;
  final Dir dir;
  final int bosOpenTime; // openTime de la vela 5M que confirmo el BOS
  final double brokenLevel;
  final double fibLo, fibHi;
  double a; // extremo estructural previo al BOS
  double b; // extremo alcanzado por el impulso posterior
  final int createdMs;

  Setup({
    required this.id,
    required this.dir,
    required this.bosOpenTime,
    required this.brokenLevel,
    required this.fibLo,
    required this.fibHi,
    required this.a,
    required this.b,
    required this.createdMs,
  });

  /// LONG: b > a, retroceso hacia abajo desde B. SHORT: b < a, retroceso hacia arriba desde B.
  double level(double r) => dir == Dir.long ? b - r * (b - a) : b + r * (a - b);
  double get zoneLow => math.min(level(fibLo), level(fibHi));
  double get zoneHigh => math.max(level(fibLo), level(fibHi));
}

class Fe50fEngine {
  final Fe50fConfig cfg;
  Fe50fEngine(this.cfg);

  final s1m = CandleSeries('1m', 60000);
  final s5m = CandleSeries('5m', 300000);
  final s1h = CandleSeries('1h', 3600000);

  void Function(EngineEvent)? onEvent;
  void Function()? onChanged;

  // ---- estado ----
  bool live = false; // false hasta terminar el bootstrap: nada historico genera senales
  double capital = 10000;
  double lastPrice = 0;
  String dataStatus = 'CONNECTING…';
  bool connected = false;

  FeState state = FeState.waitingForSetup;
  Bias bias = Bias.neutral;
  BiasResult? biasRes;
  StructureView? st5;
  List<double> ema1List = const [];
  double? ema5;
  double? ema1;
  List<double> _srLevels = const [];
  Setup? setup;
  Position? position;
  TradeResult? lastTrade;
  String lastNote = '';
  String bosText = '—';

  /// Deduplicacion: IDs de setups ya detectados y de senales ya emitidas.
  final Set<String> usedIds = <String>{};
  final Set<String> signalIds = <String>{};

  CandleSeries _s(String tf) => tf == '1m' ? s1m : (tf == '5m' ? s5m : s1h);

  void _touch() => onChanged?.call();

  void setCapital(double v) {
    if (v > 0) {
      capital = v;
      _touch();
    }
  }

  // ------------------------------------------------------------------
  // Bootstrap / historico
  // ------------------------------------------------------------------

  /// Carga historico. Las velas con closed=false se guardan solo como vela abierta.
  /// Devuelve las velas cerradas NUEVAS respecto a lo que ya habia.
  List<Candle> loadHistory(String tf, List<Candle> candles) {
    final s = _s(tf);
    final closedNew = candles.where((c) => c.closed).toList()
      ..sort((a, b) => a.openTime.compareTo(b.openTime));
    final openList = candles.where((c) => !c.closed).toList();
    final prevLast = s.closed.isEmpty ? null : s.closed.last.openTime;
    // cache no contigua con lo descargado -> se descarta
    if (s.closed.isNotEmpty &&
        closedNew.isNotEmpty &&
        s.closed.last.openTime < closedNew.first.openTime - s.intervalMs) {
      s.closed.clear();
    }
    final map = <int, Candle>{for (final c in s.closed) c.openTime: c};
    for (final c in closedNew) {
      map[c.openTime] = c;
    }
    final keys = map.keys.toList()..sort();
    s.closed
      ..clear()
      ..addAll(keys.map((k) => map[k]!));
    if (s.closed.length > s.maxLen) {
      s.closed.removeRange(0, s.closed.length - s.maxLen);
    }
    if (openList.isNotEmpty) {
      s.open = openList.last;
    } else if (s.open != null &&
        s.closed.isNotEmpty &&
        s.open!.openTime <= s.closed.last.openTime) {
      s.open = null;
    }
    if (tf == '1m' && s.closed.isNotEmpty) {
      lastPrice = (s.open ?? s.closed.last).close;
    }
    if (prevLast == null) return <Candle>[];
    return s.closed.where((c) => c.openTime > prevLast).toList();
  }

  /// Llamar tras cargar los 3 timeframes (primer arranque o reconexion).
  /// - Primer arranque: activa el modo live. NO se evalua ningun setup historico.
  /// - Si hay posicion abierta (restaurada o durante una desconexion) se revisa
  ///   el SL contra las mechas de las velas 1m posteriores a la entrada.
  void finishBootstrap() {
    _recomputeAll();
    final p = position;
    if (p != null && state == FeState.positionOpen) {
      for (final c in s1m.closed.where((c) => c.openTime > p.entryCandleOpen)) {
        if (state != FeState.positionOpen) break;
        if (_slHit(p, c.close, c.low, c.high)) {
          _closePosition(tp: false, exit: p.sl);
        }
      }
    }
    live = true;
    _touch();
  }

  // ------------------------------------------------------------------
  // Entrada de datos en vivo
  // ------------------------------------------------------------------

  void onKline(String tf, Candle c) {
    final s = _s(tf);
    // Si se perdio el cierre de la vela anterior, se promueve la abierta a cerrada.
    if (s.open != null && c.openTime > s.open!.openTime) {
      final prev = s.open!.asClosed();
      final isNew = s.apply(prev);
      _process(tf, prev, isNew);
    }
    final isNewClosed = s.apply(c); // duplicados de vela cerrada -> false
    _process(tf, c, isNewClosed);
  }

  void _process(String tf, Candle c, bool newClosed) {
    if (tf == '1m') {
      lastPrice = c.close;
    } else if (lastPrice == 0) {
      lastPrice = c.close;
    }
    if (!live) {
      _touch();
      return;
    }
    // La vela abierta SOLO se usa para precio actual y monitoreo TP/SL.
    if (state == FeState.positionOpen && position != null && tf == '1m') {
      _monitor(c, newClosed);
    }
    // Solo velas CERRADAS confirman estructura/BOS/Fib/sesgo/trigger/entrada.
    if (newClosed) {
      if (tf == '1h') {
        _recomputeBias();
      } else if (tf == '5m') {
        _recompute5m();
        _onClosed5m(c);
      } else {
        _recompute1m();
        _onClosed1m(c);
      }
    }
    _touch();
  }

  // ------------------------------------------------------------------
  // Recalculos (solo sobre velas cerradas)
  // ------------------------------------------------------------------

  void _recomputeAll() {
    _recomputeBias();
    _recompute5m();
    _recompute1m();
  }

  void _recomputeBias() {
    biasRes = computeBias1h(s1h.closed, cfg.pivotN1h);
    bias = biasRes!.bias;
    _rebuildSR();
    final s = setup;
    if (live && s != null && (state == FeState.setupDetected || state == FeState.waitingForEntry)) {
      final need = s.dir == Dir.long ? Bias.long : Bias.short;
      if (bias != need) _invalidate('1H bias changed to ${biasLabel(bias)}');
    }
  }

  void _recompute5m() {
    final cl = s5m.closed;
    st5 = analyze(cl, cfg.pivotN5m);
    final e = emaSeries(cl.map((c) => c.close).toList(), cfg.emaPeriod);
    ema5 = (e.isEmpty || e.last.isNaN) ? null : e.last;
    _rebuildSR();
  }

  void _recompute1m() {
    final cl = s1m.closed;
    ema1List = emaSeries(cl.map((c) => c.close).toList(), cfg.emaPeriod);
    ema1 = (ema1List.isEmpty || ema1List.last.isNaN) ? null : ema1List.last;
  }

  void _rebuildSR() {
    final lv = <double>[];
    final p5 = st5?.p;
    if (p5 != null) {
      lv.addAll(p5.highs.reversed.take(8).map((p) => p.price));
      lv.addAll(p5.lows.reversed.take(8).map((p) => p.price));
    }
    if (s1h.closed.length > cfg.pivotN1h * 2 + 2) {
      final p1 = findPivots(s1h.closed, cfg.pivotN1h);
      lv.addAll(p1.highs.reversed.take(6).map((p) => p.price));
      lv.addAll(p1.lows.reversed.take(6).map((p) => p.price));
    }
    _srLevels = lv;
  }

  // ------------------------------------------------------------------
  // Deteccion de setup (5M)
  // ------------------------------------------------------------------

  void _onClosed5m(Candle c) {
    if (state == FeState.positionOpen) return; // solo monitorizar
    final s = setup;
    if (s == null) {
      if (state == FeState.waitingForSetup) _tryDetect(c);
      return;
    }
    _advance(c.openTime);
    if (s.dir == Dir.long) {
      if (c.close < s.a) {
        _invalidate('5M close ${f2(c.close)} below A ${f2(s.a)}');
        return;
      }
      if (c.high > s.b) s.b = c.high; // el impulso sigue extendiendo B
    } else {
      if (c.close > s.a) {
        _invalidate('5M close ${f2(c.close)} above A ${f2(s.a)}');
        return;
      }
      if (c.low < s.b) s.b = c.low;
    }
  }

  void _advance(int candleOpenTime) {
    final s = setup;
    if (s == null) return;
    if (state == FeState.setupDetected && candleOpenTime >= s.bosOpenTime + 300000) {
      state = FeState.waitingForEntry;
    }
  }

  void _tryDetect(Candle c) {
    Setup? s;
    if (bias == Bias.long) {
      s = _detectLong(c);
    } else if (bias == Bias.short) {
      s = _detectShort(c);
    }
    if (s == null) return;
    if (usedIds.contains(s.id)) return; // deduplicacion
    usedIds.add(s.id);
    if (usedIds.length > 500) usedIds.remove(usedIds.first);
    setup = s;
    state = FeState.setupDetected;
    final t = _hhmm(s.bosOpenTime + 300000);
    bosText = s.dir == Dir.long
        ? 'BOS ↑ close > ${f2(s.brokenLevel)} @ $t'
        : 'BOS ↓ close < ${f2(s.brokenLevel)} @ $t';
    lastNote = '';
    onEvent?.call(EngineEvent('info', 'FE50F setup detected',
        '${dirLabel(s.dir)} zone ${f2(s.zoneLow)}–${f2(s.zoneHigh)}'));
  }

  Setup? _detectLong(Candle c) {
    final cl = s5m.closed;
    final n = cl.length;
    final st = st5;
    if (st == null || n < 20) return null;
    // 5M previamente LH + LL
    if (!(st.hLabel == 'LH' && st.lLabel == 'LL')) return null;
    final sh = st.lastHigh!; // el LH que hay que romper
    final sl = st.lastLow!; // el LL
    if (!(c.close > sh.price)) return null;
    // primer cierre por encima del LH desde que se formo (BOS = esta vela)
    for (var i = sh.index + 1; i < n - 1; i++) {
      if (cl[i].close > sh.price) return null;
    }
    // A = minimo estructural previo al BOS (desde el LL hasta la vela BOS)
    var a = double.infinity;
    for (var i = sl.index; i < n; i++) {
      a = math.min(a, cl[i].low);
    }
    final b = c.high;
    if (!(b > a)) return null;
    return Setup(
      id: '${cfg.symbol}|LONG|${c.openTime}|5m|FE50F',
      dir: Dir.long,
      bosOpenTime: c.openTime,
      brokenLevel: sh.price,
      fibLo: cfg.fibLo,
      fibHi: cfg.fibHi,
      a: a,
      b: b,
      createdMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Setup? _detectShort(Candle c) {
    final cl = s5m.closed;
    final n = cl.length;
    final st = st5;
    if (st == null || n < 20) return null;
    // 5M previamente HH + HL
    if (!(st.hLabel == 'HH' && st.lLabel == 'HL')) return null;
    final sh = st.lastHigh!; // el HH
    final sl = st.lastLow!; // el HL que hay que romper
    if (!(c.close < sl.price)) return null;
    for (var i = sl.index + 1; i < n - 1; i++) {
      if (cl[i].close < sl.price) return null;
    }
    var a = -double.infinity;
    for (var i = sh.index; i < n; i++) {
      a = math.max(a, cl[i].high);
    }
    final b = c.low;
    if (!(b < a)) return null;
    return Setup(
      id: '${cfg.symbol}|SHORT|${c.openTime}|5m|FE50F',
      dir: Dir.short,
      bosOpenTime: c.openTime,
      brokenLevel: sl.price,
      fibLo: cfg.fibLo,
      fibHi: cfg.fibHi,
      a: a,
      b: b,
      createdMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _invalidate(String why) {
    if (setup == null) return;
    lastNote = 'Setup invalidated: $why';
    setup = null;
    bosText = '—';
    state = FeState.waitingForSetup;
    onEvent?.call(EngineEvent('info', 'FE50F setup invalidated', why));
  }

  // ------------------------------------------------------------------
  // Trigger 1M y entrada
  // ------------------------------------------------------------------

  void _onClosed1m(Candle c) {
    if (state == FeState.positionOpen) return; // no buscar otra entrada
    final s = setup;
    if (s == null) return;
    if (c.openTime < s.bosOpenTime + 300000) return; // solo velas posteriores a la vela BOS
    _advance(c.openTime);
    final long = s.dir == Dir.long;
    if (long ? c.close < s.a : c.close > s.a) {
      _invalidate('1M close ${f2(c.close)} beyond A ${f2(s.a)}');
      return;
    }
    if (state != FeState.waitingForEntry) return;

    final cl = s1m.closed;
    final n = cl.length;
    if (n < 2 || ema1List.length != n) return;
    final e1 = ema1List[n - 1];
    final e0 = ema1List[n - 2];
    if (e1.isNaN || e0.isNaN) return;
    final c1 = cl[n - 1].close;
    final c0 = cl[n - 2].close;
    if (cl[n - 1].openTime != c.openTime) return;

    // Trigger: cruce EMA50 1M en la direccion del bias, con la vela cerrada dentro de la zona.
    final crossed = long ? (c0 <= e0 && c1 > e1) : (c0 >= e0 && c1 < e1);
    final inZone = c1 >= s.zoneLow && c1 <= s.zoneHigh;
    if (!crossed || !inZone) return;

    final sl = long ? s.a * (1 - cfg.slBuffer) : s.a * (1 + cfg.slBuffer);
    final risk = (c1 - sl).abs();
    if (risk <= 0 || (long ? c1 <= sl : c1 >= sl)) return;
    if (signalIds.contains(s.id)) return; // una oportunidad = una senal
    signalIds.add(s.id);
    if (signalIds.length > 500) signalIds.remove(signalIds.first);

    final riskUsd = capital * cfg.riskPct / 100;
    final size = riskUsd / risk; // BTC teorico
    final e5 = ema5;
    final pos = Position(
      id: s.id,
      dir: s.dir,
      entry: c1,
      sl: sl,
      priorTarget: s.b,
      sizeBtc: size,
      riskUsd: riskUsd,
      entryTime: c.openTime + 60000,
      entryCandleOpen: c.openTime,
      armed: e5 != null && (long ? c1 > e5 : c1 < e5),
    );
    position = pos;
    setup = null;
    state = FeState.positionOpen;
    final confl = <String>[
      if (_emaInZone(s)) 'EMA50 5M',
      if (_srInZone(s)) 'S/R',
    ];
    onEvent?.call(EngineEvent(
      'signal',
      'FE50F SIGNAL · ${cfg.symbol} ${dirLabel(pos.dir)}',
      'ENTRY ${f2(pos.entry)} · SL ${f2(pos.sl)} · TP dyn EMA50 5M'
          '${e5 == null ? '' : ' (${f2(e5)})'} · prior target ${f2(pos.priorTarget)} · '
          'R:R 1:${pos.rr.toStringAsFixed(2)} · RISK ${cfg.riskPct.toStringAsFixed(2)}%'
          '${confl.isEmpty ? '' : ' · confluence: ${confl.join(' + ')}'}',
    ));
  }

  bool _emaInZone(Setup s) {
    final e = ema5;
    if (e == null) return false;
    final tol = lastPrice * cfg.confTol;
    return e >= s.zoneLow - tol && e <= s.zoneHigh + tol;
  }

  bool _srInZone(Setup s) {
    final tol = lastPrice * cfg.confTol;
    return _srLevels.any((p) => p >= s.zoneLow - tol && p <= s.zoneHigh + tol);
  }

  // ------------------------------------------------------------------
  // Posicion simulada: monitoreo SL / TP dinamico
  // ------------------------------------------------------------------

  bool _slHit(Position p, double price, double? lo, double? hi) {
    if (p.dir == Dir.long) return price <= p.sl || (lo != null && lo <= p.sl);
    return price >= p.sl || (hi != null && hi >= p.sl);
  }

  void _monitor(Candle c, bool newClosed) {
    final p = position;
    if (p == null) return;
    final price = c.close;
    double? lo;
    double? hi;
    if (newClosed && c.openTime > p.entryCandleOpen) {
      lo = c.low;
      hi = c.high;
    }
    // 1) SL (prioridad si coinciden)
    if (_slHit(p, price, lo, hi)) {
      _closePosition(tp: false, exit: p.sl);
      return;
    }
    // 2) TP dinamico: cruce de la EMA50 5M en direccion contraria a la operacion.
    final e = ema5;
    if (e == null) return;
    if (p.dir == Dir.long) {
      if (price > e) p.armed = true;
      if (p.armed && price < e) _closePosition(tp: true, exit: price);
    } else {
      if (price < e) p.armed = true;
      if (p.armed && price > e) _closePosition(tp: true, exit: price);
    }
  }

  void _closePosition({required bool tp, required double exit}) {
    final p = position;
    if (p == null) return;
    final pnl = p.pnlUsd(exit);
    final res = TradeResult(
      id: p.id,
      dir: p.dir,
      tp: tp,
      entry: p.entry,
      exit: exit,
      pnlUsd: pnl,
      pnlPct: p.pnlPct(exit),
      rMultiple: p.riskUsd == 0 ? 0 : pnl / p.riskUsd,
      exitTime: DateTime.now().millisecondsSinceEpoch,
    );
    lastTrade = res;
    state = tp ? FeState.tpHit : FeState.slHit;
    final sign = pnl >= 0 ? '+' : '';
    onEvent?.call(EngineEvent(
      tp ? 'tp' : 'sl',
      tp ? 'FE50F TP HIT · ${dirLabel(p.dir)}' : 'FE50F SL HIT · ${dirLabel(p.dir)}',
      '${cfg.symbol} ${f2(p.entry)} → ${f2(exit)} · P&L $sign${f2(pnl)} USDT '
          '($sign${p.pnlPct(exit).toStringAsFixed(2)}%) · ${res.rMultiple.toStringAsFixed(2)}R',
    ));
    _touch(); // la UI puede ver TP_HIT / SL_HIT un instante
    // Limpiar y volver a esperar
    position = null;
    setup = null;
    bosText = '—';
    state = FeState.waitingForSetup;
  }

  // ------------------------------------------------------------------
  // Snapshot para la UI
  // ------------------------------------------------------------------

  String _hhmm(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    String t(int v) => v.toString().padLeft(2, '0');
    return '${t(d.hour)}:${t(d.minute)}';
  }

  String _triggerText() {
    final s = setup;
    if (state == FeState.positionOpen) return 'TRIGGERED';
    if (s == null) return '—';
    final arrow = s.dir == Dir.long ? '↑' : '↓';
    final inZone = lastPrice >= s.zoneLow && lastPrice <= s.zoneHigh;
    final zone = inZone ? 'PRICE IN ZONE' : 'PRICE OUTSIDE ZONE';
    if (state == FeState.setupDetected) return 'ARMING · 1M EMA50 CROSS $arrow · $zone';
    return 'WAITING 1M EMA50 CROSS $arrow · $zone';
  }

  Map<String, dynamic> snapshot() {
    final p = position;
    final s = setup;
    final srn = nearestSR(lastPrice, _srLevels);
    return {
      'symbol': cfg.symbol,
      'state': stateLabel(state),
      'price': lastPrice,
      'bias': biasLabel(bias),
      'structure1h': biasRes?.structure ?? '--/--',
      'note1h': biasRes?.note ?? '',
      'patterns1h': biasRes?.patterns ?? '',
      'structure5m': st5 == null ? '--/--' : '${st5!.hLabel}/${st5!.lLabel}',
      'bos': bosText,
      'fib': s == null ? '—' : '${f2(s.zoneLow)} – ${f2(s.zoneHigh)}',
      'fibAB': s == null ? '' : 'A ${f2(s.a)} · B ${f2(s.b)}',
      'emaConf': s != null && _emaInZone(s),
      'srConf': s != null && _srInZone(s),
      'ema5': ema5,
      'ema1': ema1,
      'support': srn.support,
      'resistance': srn.resistance,
      'trigger': _triggerText(),
      'data': dataStatus,
      'connected': connected,
      'live': live,
      'riskPct': cfg.riskPct,
      'capital': capital,
      'note': lastNote,
      'position': p == null
          ? null
          : {
              'dir': dirLabel(p.dir),
              'entry': p.entry,
              'sl': p.sl,
              'tp': ema5,
              'prior': p.priorTarget,
              'rr': p.rr,
              'current': lastPrice,
              'pnlUsd': p.pnlUsd(lastPrice),
              'pnlPct': p.pnlPct(lastPrice),
              'size': p.sizeBtc,
              'riskUsd': p.riskUsd,
              'armed': p.armed,
            },
      'lastTrade': lastTrade?.toJson(),
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
  }

  // ------------------------------------------------------------------
  // Persistencia (cache local)
  // ------------------------------------------------------------------

  Map<String, dynamic> exportState() {
    List<dynamic> tail(CandleSeries s) {
      final l = s.closed.length > 500 ? s.closed.sublist(s.closed.length - 500) : s.closed;
      return l.map((c) => c.toJson()).toList();
    }

    return {
      'candles': {'1m': tail(s1m), '5m': tail(s5m), '1h': tail(s1h)},
      'usedIds': usedIds.toList(),
      'signalIds': signalIds.toList(),
      'capital': capital,
      'position': position?.toJson(),
      'lastTrade': lastTrade?.toJson(),
    };
  }

  void restore(Map<String, dynamic> m) {
    try {
      final cs = m['candles'] as Map?;
      if (cs != null) {
        for (final tf in const ['1m', '5m', '1h']) {
          final l = cs[tf] as List?;
          if (l == null) continue;
          _s(tf)
            ..closed.clear()
            ..closed.addAll(l.map((e) => Candle.fromJson(e as List<dynamic>)));
        }
      }
      usedIds.addAll(((m['usedIds'] as List?) ?? const []).cast<String>());
      signalIds.addAll(((m['signalIds'] as List?) ?? const []).cast<String>());
      capital = (m['capital'] as num?)?.toDouble() ?? capital;
      final p = m['position'];
      if (p is Map) {
        position = Position.fromJson(Map<String, dynamic>.from(p));
        state = FeState.positionOpen;
      }
      final lt = m['lastTrade'];
      if (lt is Map) lastTrade = TradeResult.fromJson(Map<String, dynamic>.from(lt));
    } catch (_) {
      // cache corrupta -> se ignora y se reconstruye desde la red
    }
  }
}
