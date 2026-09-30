enum Dir { long, short }

enum Bias { long, short, neutral }

enum FeState { waitingForSetup, setupDetected, waitingForEntry, positionOpen, tpHit, slHit }

String dirLabel(Dir d) => d == Dir.long ? 'LONG' : 'SHORT';

String biasLabel(Bias b) => switch (b) {
      Bias.long => 'LONG',
      Bias.short => 'SHORT',
      Bias.neutral => 'NEUTRAL',
    };

String stateLabel(FeState s) => switch (s) {
      FeState.waitingForSetup => 'WAITING_FOR_SETUP',
      FeState.setupDetected => 'SETUP_DETECTED',
      FeState.waitingForEntry => 'WAITING_FOR_ENTRY',
      FeState.positionOpen => 'POSITION_OPEN',
      FeState.tpHit => 'TP_HIT',
      FeState.slHit => 'SL_HIT',
    };

String f2(double v) => v.toStringAsFixed(2);

class Candle {
  final int openTime; // ms epoch
  final double open, high, low, close, volume;
  final bool closed;

  const Candle({
    required this.openTime,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    this.volume = 0,
    required this.closed,
  });

  Candle asClosed() => Candle(
      openTime: openTime,
      open: open,
      high: high,
      low: low,
      close: close,
      volume: volume,
      closed: true);

  List<dynamic> toJson() => [openTime, open, high, low, close, volume];

  factory Candle.fromJson(List<dynamic> j) => Candle(
        openTime: (j[0] as num).toInt(),
        open: (j[1] as num).toDouble(),
        high: (j[2] as num).toDouble(),
        low: (j[3] as num).toDouble(),
        close: (j[4] as num).toDouble(),
        volume: (j[5] as num).toDouble(),
        closed: true,
      );
}

/// Serie de velas de un timeframe. `closed` solo contiene velas CERRADAS;
/// la vela en formacion vive aparte en `open`.
class CandleSeries {
  final String tf;
  final int intervalMs;
  final int maxLen;
  final List<Candle> closed = [];
  Candle? open;

  CandleSeries(this.tf, this.intervalMs, {this.maxLen = 1000});

  /// Devuelve true SOLO si [c] es una vela cerrada NUEVA (no duplicada).
  bool apply(Candle c) {
    if (c.closed) {
      if (closed.isNotEmpty && c.openTime <= closed.last.openTime) return false;
      closed.add(c);
      if (open != null && open!.openTime <= c.openTime) open = null;
      if (closed.length > maxLen) {
        closed.removeRange(0, closed.length - maxLen);
      }
      return true;
    }
    if (closed.isNotEmpty && c.openTime <= closed.last.openTime) return false;
    if (open != null && c.openTime < open!.openTime) return false;
    open = c;
    return false;
  }
}

class Pivot {
  final int index;
  final int time;
  final double price;
  final bool isHigh;
  const Pivot(this.index, this.time, this.price, this.isHigh);
}

class Position {
  final String id;
  final Dir dir;
  final double entry, sl, priorTarget, sizeBtc, riskUsd;
  final int entryTime;
  final int entryCandleOpen; // openTime de la vela 1m que disparo el trigger
  bool armed; // TP dinamico: precio ya estuvo del lado favorable de la EMA50 5M

  Position({
    required this.id,
    required this.dir,
    required this.entry,
    required this.sl,
    required this.priorTarget,
    required this.sizeBtc,
    required this.riskUsd,
    required this.entryTime,
    required this.entryCandleOpen,
    required this.armed,
  });

  double pnlUsd(double p) =>
      dir == Dir.long ? (p - entry) * sizeBtc : (entry - p) * sizeBtc;
  double pnlPct(double p) =>
      (dir == Dir.long ? (p - entry) : (entry - p)) / entry * 100;
  double get rr => (priorTarget - entry).abs() / (entry - sl).abs();

  Map<String, dynamic> toJson() => {
        'id': id,
        'dir': dir.name,
        'entry': entry,
        'sl': sl,
        'prior': priorTarget,
        'size': sizeBtc,
        'risk': riskUsd,
        'entryTime': entryTime,
        'entryCandleOpen': entryCandleOpen,
        'armed': armed,
      };

  factory Position.fromJson(Map<String, dynamic> j) => Position(
        id: j['id'] as String,
        dir: Dir.values.byName(j['dir'] as String),
        entry: (j['entry'] as num).toDouble(),
        sl: (j['sl'] as num).toDouble(),
        priorTarget: (j['prior'] as num).toDouble(),
        sizeBtc: (j['size'] as num).toDouble(),
        riskUsd: (j['risk'] as num).toDouble(),
        entryTime: (j['entryTime'] as num).toInt(),
        entryCandleOpen: (j['entryCandleOpen'] as num).toInt(),
        armed: j['armed'] as bool,
      );
}

class TradeResult {
  final String id;
  final Dir dir;
  final bool tp; // true = TP, false = SL
  final double entry, exit, pnlUsd, pnlPct, rMultiple;
  final int exitTime;

  const TradeResult({
    required this.id,
    required this.dir,
    required this.tp,
    required this.entry,
    required this.exit,
    required this.pnlUsd,
    required this.pnlPct,
    required this.rMultiple,
    required this.exitTime,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'dir': dir.name,
        'tp': tp,
        'entry': entry,
        'exit': exit,
        'pnlUsd': pnlUsd,
        'pnlPct': pnlPct,
        'r': rMultiple,
        'exitTime': exitTime,
      };

  factory TradeResult.fromJson(Map<String, dynamic> j) => TradeResult(
        id: j['id'] as String,
        dir: Dir.values.byName(j['dir'] as String),
        tp: j['tp'] as bool,
        entry: (j['entry'] as num).toDouble(),
        exit: (j['exit'] as num).toDouble(),
        pnlUsd: (j['pnlUsd'] as num).toDouble(),
        pnlPct: (j['pnlPct'] as num).toDouble(),
        rMultiple: (j['r'] as num).toDouble(),
        exitTime: (j['exitTime'] as num).toInt(),
      );
}

class Fe50fConfig {
  final String symbol;
  final int pivotN5m; // velas a cada lado para confirmar un pivote 5M
  final int pivotN1h; // idem 1H
  final int emaPeriod;
  final double fibLo, fibHi;
  final double riskPct; // % del capital
  final double confTol; // tolerancia de confluencia EMA50/SR con la zona (fraccion del precio)
  final double slBuffer; // colchon opcional del SL (fraccion del precio); 0 = SL exacto en A

  const Fe50fConfig({
    this.symbol = 'BTCUSDT',
    this.pivotN5m = 3,
    this.pivotN1h = 2,
    this.emaPeriod = 50,
    this.fibLo = 0.382,
    this.fibHi = 0.75,
    this.riskPct = 0.5,
    this.confTol = 0.0015,
    this.slBuffer = 0.0,
  });
}
