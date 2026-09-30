import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';

const _green = Color(0xFF26A69A);
const _red = Color(0xFFEF5350);
const _grey = Colors.white54;

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _svc = FlutterBackgroundService();
  Map<String, dynamic>? _snap;
  StreamSubscription? _sub;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _sub = _svc.on('snapshot').listen((d) {
      if (d != null && mounted) setState(() => _snap = d);
    });
    _svc.invoke('requestSnapshot');
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _svc.invoke('requestSnapshot'));
    WidgetsBinding.instance.addPostFrameCallback((_) => _askBattery());
  }

  Future<void> _askBattery() async {
    try {
      if (!await Permission.ignoreBatteryOptimizations.isGranted) {
        await Permission.ignoreBatteryOptimizations.request();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _sub?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  // ---------- helpers ----------
  String _n(dynamic v) => v is num ? v.toStringAsFixed(2) : '—';
  Color _biasColor(String b) => b == 'LONG' ? _green : (b == 'SHORT' ? _red : _grey);

  Widget _kv(String k, String v, {Color? color, String? sub}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 118,
              child: Text(k,
                  style: const TextStyle(color: _grey, fontSize: 12, letterSpacing: 0.6))),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(v,
                  style: TextStyle(
                      color: color ?? Colors.white,
                      fontFamily: 'monospace',
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              if (sub != null && sub.isNotEmpty)
                Text(sub, style: const TextStyle(color: _grey, fontSize: 11)),
            ]),
          ),
        ]),
      );

  Widget _card(List<Widget> children, {Color? border}) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF121820),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border ?? Colors.white10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Future<void> _editCapital(double current) async {
    final ctrl = TextEditingController(text: current.toStringAsFixed(0));
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Theoretical capital (USDT)'),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, double.tryParse(ctrl.text.replaceAll(',', '.'))),
              child: const Text('Save')),
        ],
      ),
    );
    if (v != null && v > 0) _svc.invoke('setCapital', {'capital': v});
  }

  @override
  Widget build(BuildContext context) {
    final s = _snap;
    return Scaffold(
      body: SafeArea(
        child: s == null
            ? const Center(child: Text('FE50F · starting engine…'))
            : ListView(padding: const EdgeInsets.all(14), children: _content(s)),
      ),
    );
  }

  List<Widget> _content(Map<String, dynamic> s) {
    final bias = s['bias'] as String;
    final pos = s['position'] as Map?;
    final last = s['lastTrade'] as Map?;
    final connected = s['connected'] == true;
    final capital = (s['capital'] as num).toDouble();

    return [
      // Cabecera
      Row(children: [
        const Text('FE50F', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        const SizedBox(width: 10),
        Text(s['symbol'] as String, style: const TextStyle(fontSize: 16, color: _grey)),
        const Spacer(),
        Text(_n(s['price']),
            style: const TextStyle(
                fontFamily: 'monospace', fontSize: 18, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
              color: Colors.white10, borderRadius: BorderRadius.circular(20)),
          child: Text('STATUS  ${s['state']}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ]),
      const SizedBox(height: 12),

      // Senal / operacion
      if (pos != null) ..._positionCards(s, pos),

      if (pos == null && last != null) _lastTradeCard(last),

      // Panel de analisis
      _card([
        _kv('1H BIAS', bias, color: _biasColor(bias), sub: s['note1h'] as String?),
        _kv('1H STRUCTURE', s['structure1h'] as String, sub: s['patterns1h'] as String?),
        _kv('5M STRUCTURE', s['structure5m'] as String),
        _kv('5M BOS', s['bos'] as String),
        _kv('FIB 0.382–0.75', s['fib'] as String, sub: s['fibAB'] as String?),
        _kv('EMA50', '5M ${_n(s['ema5'])}  ·  1M ${_n(s['ema1'])}',
            sub: 'confluence: EMA50 5M ${s['emaConf'] == true ? '✔' : '✘'}  ·  S/R ${s['srConf'] == true ? '✔' : '✘'}'),
        _kv('S/R', 'S ${_n(s['support'])}  ·  R ${_n(s['resistance'])}'),
        _kv('1M TRIGGER', s['trigger'] as String),
        _kv('DATA', s['data'] as String, color: connected ? _green : _red),
        if ((s['note'] as String).isNotEmpty) _kv('NOTE', s['note'] as String),
      ]),

      // Capital teorico
      _card([
        Row(children: [
          Expanded(
              child: Text('RISK ${(s['riskPct'] as num).toStringAsFixed(2)}% of ${capital.toStringAsFixed(0)} USDT (theoretical)',
                  style: const TextStyle(color: _grey, fontSize: 12))),
          TextButton(onPressed: () => _editCapital(capital), child: const Text('Edit')),
        ]),
        const Text('Simulation only · no real orders · no API keys',
            style: TextStyle(color: _grey, fontSize: 11)),
      ]),
    ];
  }

  List<Widget> _positionCards(Map<String, dynamic> s, Map pos) {
    final long = pos['dir'] == 'LONG';
    final c = long ? _green : _red;
    final pnl = (pos['pnlUsd'] as num).toDouble();
    final pnlPct = (pos['pnlPct'] as num).toDouble();
    final pc = pnl >= 0 ? _green : _red;
    final sign = pnl >= 0 ? '+' : '';
    return [
      _card([
        Text('FE50F SIGNAL', style: TextStyle(color: c, fontWeight: FontWeight.w800, letterSpacing: 1)),
        const SizedBox(height: 6),
        Text('${s['symbol']} ${pos['dir']}',
            style: TextStyle(color: c, fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        _kv('ENTRY', _n(pos['entry'])),
        _kv('SL', _n(pos['sl']), color: _red),
        _kv('TP', 'EMA50 5M dynamic · ${_n(pos['tp'])}',
            sub: 'prior target ${_n(pos['prior'])}'),
        _kv('R:R', '1:${_n(pos['rr'])}  (to prior target)'),
        _kv('RISK', '${(s['riskPct'] as num).toStringAsFixed(2)}%  ≈ ${_n(pos['riskUsd'])} USDT'),
        _kv('STATUS', 'POSITION OPEN', color: c),
      ], border: c),
      _card([
        const Text('LIVE POSITION', style: TextStyle(color: _grey, letterSpacing: 1, fontSize: 12)),
        const SizedBox(height: 6),
        _kv('ENTRY', _n(pos['entry'])),
        _kv('CURRENT', _n(pos['current'])),
        _kv('SL', _n(pos['sl'])),
        _kv('TP', _n(pos['tp']), sub: pos['armed'] == true ? 'armed' : 'not armed yet (price not on favorable side of EMA50 5M)'),
        _kv('P&L', '$sign${_n(pnl)} USDT  ($sign${pnlPct.toStringAsFixed(2)}%)', color: pc),
        _kv('STATUS', 'POSITION OPEN', color: c),
      ]),
    ];
  }

  Widget _lastTradeCard(Map t) {
    final tp = t['tp'] == true;
    final pnl = (t['pnlUsd'] as num).toDouble();
    final sign = pnl >= 0 ? '+' : '';
    return _card([
      Text(tp ? 'TP HIT' : 'SL HIT',
          style: TextStyle(
              color: tp ? _green : _red, fontWeight: FontWeight.w800, fontSize: 16)),
      const SizedBox(height: 4),
      Text(
          '${t['dir'].toString().toUpperCase()} ${_n(t['entry'])} → ${_n(t['exit'])}  ·  $sign${_n(pnl)} USDT  ·  ${_n(t['r'])}R',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      const Text('→ back to WAITING_FOR_SETUP', style: TextStyle(color: _grey, fontSize: 11)),
    ]);
  }
}
