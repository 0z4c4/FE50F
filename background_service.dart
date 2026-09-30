import 'dart:async';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';

import '../data/market_feed.dart';
import '../data/store.dart';
import '../engine/fe50f_engine.dart';
import 'notification_service.dart';

Future<void> initializeService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: NotificationService.monitorChannelId,
      initialNotificationTitle: 'FE50F',
      initialNotificationContent: 'Monitoring BTCUSDT · Starting…',
      foregroundServiceNotificationId: 5050,
      foregroundServiceTypes: [AndroidForegroundType.specialUse],
    ),
    iosConfiguration: IosConfiguration(autoStart: false, onForeground: onStart),
  );
  if (!await service.isRunning()) {
    await service.startService();
  }
}

/// Punto de entrada del isolate del servicio en primer plano: aqui vive TODO
/// (WebSocket + motor FE50F + notificaciones). La UI solo recibe snapshots.
@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  await ServiceRunner(service).start();
}

class ServiceRunner {
  ServiceRunner(this.service);
  final ServiceInstance service;

  late final Fe50fEngine engine;
  late final MarketFeed feed;
  final notifier = NotificationService();
  Timer? _timer;
  bool _dirty = true;
  bool _saveNeeded = false;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> start() async {
    await notifier.init();
    engine = Fe50fEngine(const Fe50fConfig());
    final saved = await Fe50fStore.load();
    if (saved != null) engine.restore(saved);

    engine.onChanged = () {
      _dirty = true;
      _saveNeeded = true;
    };
    engine.onEvent = (e) {
      notifier.showEvent(e);
      _persist(force: true);
    };
    feed = MarketFeed(engine, onStatus: _onStatus);

    service.on('requestSnapshot').listen((_) => _push());
    service.on('setCapital').listen((d) {
      final v = (d?['capital'] as num?)?.toDouble();
      if (v != null) engine.setCapital(v);
    });
    service.on('stopService').listen((_) async {
      feed.stop();
      await _persist(force: true);
      _timer?.cancel();
      service.stopSelf();
    });

    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_dirty) _push();
      _persist();
    });
    feed.start();
  }

  void _onStatus(String text, bool connected, String source) {
    engine.dataStatus = text;
    engine.connected = connected;
    _dirty = true;
    final name = source == 'OKX' ? 'OKX' : 'Binance';
    try {
      // Solo existe en la instancia Android del servicio.
      (service as dynamic).setForegroundNotificationInfo(
        title: 'FE50F',
        content: connected
            ? 'Monitoring BTCUSDT · $name WebSocket Connected'
            : 'Monitoring BTCUSDT · Reconnecting…',
      );
    } catch (_) {}
  }

  void _push() {
    _dirty = false;
    service.invoke('snapshot', engine.snapshot());
  }

  Future<void> _persist({bool force = false}) async {
    if (!force && (!_saveNeeded || DateTime.now().difference(_lastSave).inSeconds < 15)) return;
    _saveNeeded = false;
    _lastSave = DateTime.now();
    await Fe50fStore.save(engine.exportState());
  }
}
