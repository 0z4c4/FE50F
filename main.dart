import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'services/background_service.dart';
import 'services/notification_service.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 1) canales + permiso de notificaciones, 2) servicio en primer plano (arranca solo).
  await NotificationService.createChannels(FlutterLocalNotificationsPlugin());
  await initializeService();
  runApp(const Fe50fApp());
}

class Fe50fApp extends StatelessWidget {
  const Fe50fApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FE50F',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0F14),
        colorScheme: const ColorScheme.dark(primary: Color(0xFF4DD0E1)),
      ),
      home: const HomePage(),
    );
  }
}
