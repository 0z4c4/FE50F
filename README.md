# FE50F — app Android (Flutter)

Motor FE50F local sobre BTCUSDT: Binance WebSocket público → motor de estrategia → señal/notificación.
Sin servidor, sin Telegram, sin API keys, **sin órdenes reales** (solo simulación TP/SL).

## Compilar el APK

Requisitos: Flutter SDK estable (>=3.22), JDK 17, Android SDK.

    ./setup_android.sh     # flutter create + manifest + parche Gradle (una sola vez)
    ./build_apk.sh         # -> build/app/outputs/flutter-apk/app-release.apk

Sin Flutter local: sube esta carpeta a un repo de GitHub y ejecuta el workflow
**Build FE50F APK** (Actions); descarga el artefacto `FE50F-apk`.

Instalar: `adb install -r app-release.apk` o copiar el APK al móvil (permitir orígenes desconocidos).
En el primer arranque acepta: notificaciones y "ignorar optimización de batería" (necesario para
mantener el WebSocket con la pantalla apagada).

## Estructura

    lib/engine/   models, indicators (EMA), structure (pivotes/sesgo/S-R), fe50f_engine (máquina de estados)
    lib/data/     market_feed (Binance WS + REST, OKX fallback, reconexión), store (caché local JSON)
    lib/services/ background_service (Foreground Service + isolate), notification_service
    lib/ui/       home_page

El motor corre en el isolate del Foreground Service; la UI solo muestra snapshots.

## Reglas ambiguas del spec y cómo se interpretaron (todas ajustables en `Fe50fConfig`/motor)

1. **SL "definido por FE50F"**: el spec no da el nivel. Se usa **A** (extremo estructural previo al BOS, 100% del Fib). `slBuffer` opcional.
2. **TP dinámico**: "cruce de EMA50 5M en dirección contraria". Se implementó literal: LONG cierra cuando el precio cruza la EMA50 5M **hacia abajo**, SHORT hacia arriba. Guardia: solo se "arma" tras haber estado el precio del lado favorable (si no, cerraría al instante cuando la entrada está bajo la EMA). El cierre puede dar P&L negativo y aun así se etiqueta TP HIT.
3. **R:R**: como el TP es dinámico, se calcula contra el **prior target = B** (extremo del impulso).
4. **EMA50 5M y S/R** se tratan como **confluencia informativa** (no bloquean). El **trigger 1M es siempre obligatorio**.
5. **Trigger**: vela 1M cerrada que cruza la EMA50 1M en dirección del bias y cuyo cierre está dentro de la zona 0.382–0.75. Entrada = cierre de esa vela.
6. **A/B**: LONG → A = mínimo desde el último LL hasta la vela BOS; B = máximo de velas 5M cerradas desde el BOS (se extiende mientras el impulso continúa). SHORT simétrico.
7. **Pivotes**: 3 velas a cada lado en 5M, 2 en 1H (`pivotN5m`, `pivotN1h`).
8. **Invalidación**: cierre (1M/5M) más allá de A, o cambio del sesgo 1H, antes de la entrada.
9. **Sesgo 1H**: cierre 1H que rompe el último HL (o LH) → NEUTRAL hasta nueva estructura. Doble techo/suelo y engulfing solo se muestran, no cambian el sesgo.
10. **Arranque**: el motor solo evalúa BOS de velas 5M cerradas *después* de abrir la app. Si había una posición simulada abierta, se restaura y se revisa el SL contra mechas 1m.
11. **Foreground Service**: tipo `specialUse` (evita el límite de 6 h de `dataSync` en Android 15). Válido para APK instalado directamente; Google Play exigiría declaración.
