import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../engine/fe50f_engine.dart';
import '../engine/models.dart';

/// Feed publico BTCUSDT (1m/5m/1h). Binance por defecto, OKX como fallback.
/// Sin API keys. Reconexion automatica con backoff + watchdog de silencio.
class MarketFeed {
  MarketFeed(this.engine, {required this.onStatus});

  final Fe50fEngine engine;
  final void Function(String text, bool connected, String source) onStatus;

  static const symbol = 'BTCUSDT';
  static const tfs = ['1m', '5m', '1h'];
  static const binanceWs =
      'wss://data-stream.binance.vision/stream?streams=btcusdt@kline_1m/btcusdt@kline_5m/btcusdt@kline_1h';
  static const okxWs = 'wss://ws.okx.com:8443/ws/v5/business';

  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  Timer? _watchdog;
  Timer? _retry;
  bool _stopped = false;
  bool _connected = false;
  bool _useOkx = false;
  int _fails = 0;
  int _seq = 0;
  int _ticks = 0;
  DateTime _lastMsg = DateTime.now();

  void start() {
    _stopped = false;
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
      _ticks++;
      if (_connected && DateTime.now().difference(_lastMsg) > const Duration(seconds: 30)) {
        _reconnect('stale');
        return;
      }
      if (_connected && _useOkx) {
        _ch?.sink.add('ping'); // keep-alive OKX
        if (_ticks % 30 == 0) {
          _useOkx = false; // reintentar la fuente primaria cada ~5 min
          _reconnect('retry primary');
        }
      }
    });
    _connect();
  }

  void stop() {
    _stopped = true;
    _watchdog?.cancel();
    _retry?.cancel();
    _closeSocket();
  }

  void _closeSocket() {
    _sub?.cancel();
    _sub = null;
    try {
      _ch?.sink.close();
    } catch (_) {}
    _ch = null;
  }

  Future<void> _connect() async {
    if (_stopped) return;
    final seq = ++_seq;
    _closeSocket();
    final src = _useOkx ? 'OKX' : 'BINANCE';
    onStatus('CONNECTING $src…', false, src);
    try {
      for (final tf in tfs) {
        final list = _useOkx ? await _okxRest(tf) : await _binanceRest(tf);
        if (seq != _seq || _stopped) return;
        engine.loadHistory(tf, list);
      }
      engine.finishBootstrap();
      final ch = WebSocketChannel.connect(Uri.parse(_useOkx ? okxWs : binanceWs));
      await ch.ready.timeout(const Duration(seconds: 12));
      if (seq != _seq || _stopped) {
        ch.sink.close();
        return;
      }
      _ch = ch;
      _lastMsg = DateTime.now();
      if (_useOkx) {
        ch.sink.add(jsonEncode({
          'op': 'subscribe',
          'args': [
            {'channel': 'candle1m', 'instId': 'BTC-USDT'},
            {'channel': 'candle5m', 'instId': 'BTC-USDT'},
            {'channel': 'candle1H', 'instId': 'BTC-USDT'},
          ],
        }));
      }
      _sub = ch.stream.listen(
        (m) {
          _lastMsg = DateTime.now();
          _onMessage(m);
        },
        onError: (_) => _reconnect('error', seq),
        onDone: () => _reconnect('closed', seq),
        cancelOnError: true,
      );
      _connected = true;
      _fails = 0;
      onStatus(_useOkx ? 'OKX WS CONNECTED (FALLBACK)' : 'BINANCE WS CONNECTED', true, src);
    } catch (_) {
      if (seq == _seq && !_stopped) _scheduleRetry();
    }
  }

  void _reconnect(String reason, [int? seq]) {
    if (_stopped) return;
    if (seq != null && seq != _seq) return;
    _scheduleRetry();
  }

  void _scheduleRetry() {
    _connected = false;
    _closeSocket();
    _fails++;
    if (_fails % 3 == 0) _useOkx = !_useOkx; // alterna Binance <-> OKX tras 3 fallos
    final d = Duration(seconds: math.min(30, 1 << math.min(_fails, 5)));
    onStatus('RECONNECTING… (${d.inSeconds}s)', false, _useOkx ? 'OKX' : 'BINANCE');
    _retry?.cancel();
    _retry = Timer(d, _connect);
  }

  // ---------------- mensajes ----------------

  void _onMessage(dynamic raw) {
    try {
      if (raw is! String) return;
      if (raw == 'pong') return;
      final j = jsonDecode(raw);
      if (j is! Map) return;
      if (_useOkx) {
        _onOkx(j);
      } else {
        _onBinance(j);
      }
    } catch (e) {
      // mensaje malformado: se ignora, el stream sigue
    }
  }

  void _onBinance(Map j) {
    final d = (j['data'] ?? j) as Map;
    if (d['e'] != 'kline') return;
    final k = d['k'] as Map;
    final tf = k['i'] as String;
    if (!tfs.contains(tf)) return;
    engine.onKline(
      tf,
      Candle(
        openTime: (k['t'] as num).toInt(),
        open: double.parse(k['o'] as String),
        high: double.parse(k['h'] as String),
        low: double.parse(k['l'] as String),
        close: double.parse(k['c'] as String),
        volume: double.parse(k['v'] as String),
        closed: k['x'] == true,
      ),
    );
  }

  void _onOkx(Map j) {
    final arg = j['arg'];
    final data = j['data'];
    if (arg is! Map || data is! List) return;
    final tf = switch (arg['channel']) {
      'candle1m' => '1m',
      'candle5m' => '5m',
      'candle1H' => '1h',
      _ => null,
    };
    if (tf == null) return;
    for (final row in data) {
      engine.onKline(tf, _okxCandle(row as List, closed: row[8] == '1'));
    }
  }

  Candle _okxCandle(List r, {required bool closed}) => Candle(
        openTime: int.parse(r[0] as String),
        open: double.parse(r[1] as String),
        high: double.parse(r[2] as String),
        low: double.parse(r[3] as String),
        close: double.parse(r[4] as String),
        volume: double.parse(r[5] as String),
        closed: closed,
      );

  // ---------------- REST bootstrap ----------------

  Future<List<Candle>> _binanceRest(String tf) async {
    final r = await http
        .get(Uri.parse(
            'https://data-api.binance.vision/api/v3/klines?symbol=$symbol&interval=$tf&limit=500'))
        .timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) throw Exception('Binance REST ${r.statusCode}');
    final rows = jsonDecode(r.body) as List;
    final out = <Candle>[];
    for (var i = 0; i < rows.length; i++) {
      final k = rows[i] as List;
      out.add(Candle(
        openTime: (k[0] as num).toInt(),
        open: double.parse(k[1] as String),
        high: double.parse(k[2] as String),
        low: double.parse(k[3] as String),
        close: double.parse(k[4] as String),
        volume: double.parse(k[5] as String),
        // la ultima vela devuelta por REST siempre es la que esta en formacion
        closed: i < rows.length - 1,
      ));
    }
    return out;
  }

  Future<List<Candle>> _okxRest(String tf) async {
    final bar = tf == '1h' ? '1H' : tf;
    final r = await http
        .get(Uri.parse('https://www.okx.com/api/v5/market/candles?instId=BTC-USDT&bar=$bar&limit=300'))
        .timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) throw Exception('OKX REST ${r.statusCode}');
    final data = (jsonDecode(r.body) as Map)['data'] as List;
    final out = <Candle>[];
    for (final row in data.reversed) {
      final l = row as List;
      out.add(_okxCandle(l, closed: l[8] == '1'));
    }
    return out;
  }
}
