import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../engine/fe50f_engine.dart';

class NotificationService {
  static const monitorChannelId = 'fe50f_monitor';
  static const signalsChannelId = 'fe50f_signals';

  final FlutterLocalNotificationsPlugin plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    await plugin.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
  }

  /// Crea los canales (el del servicio en primer plano DEBE existir antes de arrancarlo)
  /// y pide el permiso de notificaciones (Android 13+).
  static Future<void> createChannels(FlutterLocalNotificationsPlugin p) async {
    final a = p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await a?.createNotificationChannel(const AndroidNotificationChannel(
      monitorChannelId,
      'FE50F Monitoring',
      description: 'Persistent monitoring notification',
      importance: Importance.low,
    ));
    await a?.createNotificationChannel(const AndroidNotificationChannel(
      signalsChannelId,
      'FE50F Signals',
      description: 'Signal and TP/SL notifications',
      importance: Importance.high,
    ));
    await a?.requestNotificationsPermission();
  }

  /// Notificacion local SOLO al generar senal y al terminar por TP/SL.
  Future<void> showEvent(EngineEvent e) async {
    if (e.kind != 'signal' && e.kind != 'tp' && e.kind != 'sl') return;
    await plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000 % 2000000000,
      e.title,
      e.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          signalsChannelId,
          'FE50F Signals',
          channelDescription: 'Signal and TP/SL notifications',
          importance: Importance.high,
          priority: Priority.high,
          styleInformation: BigTextStyleInformation(e.body),
        ),
      ),
    );
  }
}
