import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
// FIX: kIsWeb lives in foundation.dart. material.dart re-exports most of
// foundation but NOT the platform constants, so this import is required
// for the Flutter-web CORS detection in TwilioService.sendMessage.
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const WeatherAlertApp());
}

// ─── COSMIC THEME ─────────────────────────────────────────────────────────────
class AppColors {
  static const bg           = Color(0xFF06040F);
  static const bgDeep       = Color(0xFF030208);
  static const panel        = Color(0xFF0D0A1A);
  static const card         = Color(0xFF120E22);
  static const cardGlow     = Color(0xFF1A1430);
  static const border       = Color(0x22A78BFA);
  static const borderBright = Color(0x55A78BFA);
  static const accent       = Color(0xFFA78BFA); // violet
  static const accentSoft   = Color(0xFF7C3AED);
  static const accentPink   = Color(0xFFF472B6); // pink
  static const accentCyan   = Color(0xFF67E8F9); // cyan star
  static const accentGold   = Color(0xFFFBBF24);
  static const nebula1      = Color(0xFF4C1D95);
  static const nebula2      = Color(0xFF831843);
  static const textPrimary  = Color(0xFFF1EEF9);
  static const textSub      = Color(0xFFB8AEDA);
  static const textMuted    = Color(0xFF6B5E8A);
  static const success      = Color(0xFF6EE7B7);
  static const warning      = Color(0xFFFBBF24);
  static const danger       = Color(0xFFF87171);
}

// ─── DATA MODELS ──────────────────────────────────────────────────────────────
class HourlyItem {
  final String time, icon;
  final int temp;
  final double rain;
  final bool isNow;
  HourlyItem({required this.time, required this.icon, required this.temp, this.rain = 0, this.isNow = false});
}

class DailyItem {
  final String day, icon, desc;
  final int min, max;
  final double rainPct;
  DailyItem({required this.day, required this.icon, required this.desc, required this.min, required this.max, required this.rainPct});
}

class WeatherData {
  final double temperature, humidity, windSpeed, rainChance, feelsLike;
  final String description, cityName;
  final List<HourlyItem> hourly;
  final List<DailyItem> daily;
  final int uvIndex;
  final double visibility;
  final int cloudCover;
  final DateTime fetchedAt;

  WeatherData({
    required this.temperature, required this.humidity, required this.windSpeed,
    required this.rainChance, required this.feelsLike, required this.description,
    required this.cityName, required this.hourly, required this.daily,
    required this.uvIndex, required this.visibility, required this.cloudCover,
    DateTime? fetchedAt,
  }) : fetchedAt = fetchedAt ?? DateTime.now();
}

// ─── WEATHER SERVICE (Open-Meteo — free, real-time, no API key) ───────────────
class WeatherService {
  static Future<Map<String, dynamic>?> geocode(String city) async {
    final url = Uri.parse(
      'https://geocoding-api.open-meteo.com/v1/search?name=${Uri.encodeComponent(city)}&count=1&language=en&format=json',
    );
    try {
      final res = await http.get(url).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      if (data['results'] == null || (data['results'] as List).isEmpty) return null;
      final r = data['results'][0];
      return {
        'lat': (r['latitude'] as num).toDouble(),
        'lon': (r['longitude'] as num).toDouble(),
        'name': r['name'] ?? city,
        'country': r['country_code'] ?? '',
      };
    } catch (_) { return null; }
  }

  static Future<String?> reverseGeocode(double lat, double lon) async {
    final url = Uri.parse(
      'https://api.bigdatacloud.net/data/reverse-geocode-client'
      '?latitude=$lat&longitude=$lon&localityLanguage=en',
    );
    try {
      final res = await http.get(url).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final d = jsonDecode(res.body) as Map<String, dynamic>;
      final city = (d['city'] ?? d['locality'] ?? d['principalSubdivision'] ?? '') as String;
      final cc   = (d['countryCode'] ?? '') as String;
      if (city.isEmpty && cc.isEmpty) return null;
      return cc.isEmpty ? city : '$city, $cc';
    } catch (_) { return null; }
  }

  static Future<WeatherData?> fetchWeather(double lat, double lon, String cityName) async {
    final url = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=$lat&longitude=$lon'
      '&current=temperature_2m,relative_humidity_2m,apparent_temperature,'
      'wind_speed_10m,weather_code,cloud_cover,visibility'
      '&hourly=temperature_2m,precipitation_probability,weather_code'
      '&daily=temperature_2m_max,temperature_2m_min,'
      'precipitation_probability_max,weather_code,uv_index_max'
      '&timezone=auto&forecast_days=7',
    );
    try {
      final res = await http.get(url).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final d = jsonDecode(res.body);
      final cur       = d['current']  as Map<String, dynamic>;
      final hourlyMap = d['hourly']   as Map<String, dynamic>;
      final dailyMap  = d['daily']    as Map<String, dynamic>;

      final now   = DateTime.now();
      final times = (hourlyMap['time'] as List).map((t) => DateTime.parse(t)).toList();
      int startIdx = 0;
      for (int i = 0; i < times.length; i++) {
        if (!times[i].isBefore(now)) { startIdx = i; break; }
      }

      final hourly = List.generate(12, (i) {
        final idx = startIdx + i;
        if (idx >= times.length) { return HourlyItem(time: '--', icon: '❓', temp: 0); }
        return HourlyItem(
          time:   i == 0 ? 'Now' : _formatHour(times[idx]),
          icon:   _wmoEmoji((hourlyMap['weather_code'] as List)[idx] as int),
          temp:   ((hourlyMap['temperature_2m'] as List)[idx] as num).toInt(),
          rain:   ((hourlyMap['precipitation_probability'] as List)[idx] as num) / 100.0,
          isNow:  i == 0,
        );
      });

      final daily = List.generate((dailyMap['time'] as List).length, (i) => DailyItem(
        day:     i == 0 ? 'Today' : _shortDay((dailyMap['time'] as List)[i] as String),
        icon:    _wmoEmoji((dailyMap['weather_code'] as List)[i] as int),
        desc:    _wmoDesc((dailyMap['weather_code'] as List)[i] as int),
        min:     ((dailyMap['temperature_2m_min'] as List)[i] as num).toInt(),
        max:     ((dailyMap['temperature_2m_max'] as List)[i] as num).toInt(),
        rainPct: ((dailyMap['precipitation_probability_max'] as List)[i] as num) / 100.0,
      ));

      final rainPct = startIdx < (hourlyMap['precipitation_probability'] as List).length
          ? ((hourlyMap['precipitation_probability'] as List)[startIdx] as num) / 100.0
          : 0.0;

      return WeatherData(
        temperature: (cur['temperature_2m'] as num).toDouble(),
        humidity:    (cur['relative_humidity_2m'] as num).toDouble(),
        windSpeed:   (cur['wind_speed_10m'] as num).toDouble(),
        feelsLike:   (cur['apparent_temperature'] as num).toDouble(),
        rainChance:  rainPct,
        description: _wmoDesc(cur['weather_code'] as int),
        cityName:    cityName,
        hourly:      hourly,
        daily:       daily,
        uvIndex:     daily.isNotEmpty ? ((dailyMap['uv_index_max'] as List)[0] as num).toInt() : 0,
        visibility:  cur['visibility'] != null ? (cur['visibility'] as num).toDouble() / 1000.0 : 10.0,
        cloudCover:  (cur['cloud_cover'] as num).toInt(),
        fetchedAt:   DateTime.now(),
      );
    } catch (e) {
      debugPrint('WeatherService error: $e');
      return null;
    }
  }

  static String _wmoDesc(int c) {
    if (c == 0) return 'Clear Sky';
    if (c <= 2) return 'Partly Cloudy';
    if (c == 3) return 'Overcast';
    if (c <= 49) return 'Foggy';
    if (c <= 57) return 'Drizzle';
    if (c <= 67) return 'Rainy';
    if (c <= 77) return 'Snowy';
    if (c <= 82) return 'Heavy Showers';
    if (c <= 99) return 'Thunderstorm';
    return 'Unknown';
  }

  static String _wmoEmoji(int c) {
    if (c == 0) return '☀️';
    if (c <= 2) return '⛅';
    if (c == 3) return '☁️';
    if (c <= 49) return '🌫️';
    if (c <= 57) return '🌦️';
    if (c <= 67) return '🌧️';
    if (c <= 77) return '❄️';
    if (c <= 82) return '🌩️';
    if (c <= 99) return '⛈️';
    return '❓';
  }

  static String _formatHour(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    return '$h ${dt.hour >= 12 ? 'PM' : 'AM'}';
  }

  static String _shortDay(String iso) {
    final d = DateTime.parse(iso);
    return ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][d.weekday - 1];
  }
}

// ─── NEBULA PAINTER (animated background) ─────────────────────────────────────
class NebulaPainter extends CustomPainter {
  final double t;
  NebulaPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final blobs = [
      _Blob(w * 0.15, h * 0.25, w * 0.55, AppColors.nebula1.withValues(alpha: 0.18), t * 0.4),
      _Blob(w * 0.75, h * 0.15, w * 0.45, AppColors.nebula2.withValues(alpha: 0.12), t * 0.3 + 1.2),
      _Blob(w * 0.50, h * 0.75, w * 0.50, AppColors.accentSoft.withValues(alpha: 0.10), t * 0.25 + 2.4),
      _Blob(w * 0.85, h * 0.65, w * 0.35, AppColors.nebula1.withValues(alpha: 0.08), t * 0.35 + 0.8),
    ];

    for (final b in blobs) {
      final dx = math.sin(b.phase) * w * 0.04;
      final dy = math.cos(b.phase * 0.7) * h * 0.03;
      final paint = Paint()
        ..shader = RadialGradient(colors: [b.color, Colors.transparent])
            .createShader(Rect.fromCircle(center: Offset(b.cx + dx, b.cy + dy), radius: b.r));
      canvas.drawCircle(Offset(b.cx + dx, b.cy + dy), b.r, paint);
    }

    final rng = math.Random(42);
    for (int i = 0; i < 120; i++) {
      final sx   = rng.nextDouble() * w;
      final sy   = rng.nextDouble() * h;
      final twinkle = (math.sin(t * 1.5 + i * 0.8) + 1) / 2;
      final opacity = 0.15 + twinkle * 0.55;
      final radius  = 0.5 + rng.nextDouble() * 1.2;
      canvas.drawCircle(
        Offset(sx, sy),
        radius,
        Paint()..color = Colors.white.withValues(alpha: opacity),
      );
    }
  }

  @override
  bool shouldRepaint(NebulaPainter old) => old.t != t;
}

class _Blob {
  final double cx, cy, r, phase;
  final Color color;
  _Blob(this.cx, this.cy, this.r, this.color, this.phase);
}

// ─── NEBULA BACKGROUND WIDGET ─────────────────────────────────────────────────
class NebulaBackground extends StatefulWidget {
  final Widget child;
  const NebulaBackground({super.key, required this.child});
  @override State<NebulaBackground> createState() => _NebulaBackgroundState();
}

class _NebulaBackgroundState extends State<NebulaBackground> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 20))..repeat();
  }
  @override void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) => CustomPaint(
        painter: NebulaPainter(_ctrl.value * math.pi * 2),
        child: child,
      ),
      child: widget.child,
    );
  }
}

// ─── WAVE SHIMMER (loading placeholder) ───────────────────────────────────────
class WaveShimmer extends StatefulWidget {
  final double width, height, radius;
  const WaveShimmer({super.key, this.width = double.infinity, this.height = 60, this.radius = 12});
  @override State<WaveShimmer> createState() => _WaveShimmerState();
}
class _WaveShimmerState extends State<WaveShimmer> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override void initState() { super.initState(); _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat(); }
  @override void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) => Container(
        width: widget.width, height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          gradient: LinearGradient(
            begin: Alignment(-1 + _ctrl.value * 2.5, 0),
            end:   Alignment( 0 + _ctrl.value * 2.5, 0),
            colors: [AppColors.card, AppColors.cardGlow, AppColors.card],
          ),
        ),
      ),
    );
  }
}

// ─── PULSE DOT ────────────────────────────────────────────────────────────────
class PulseDot extends StatefulWidget {
  final Color color;
  final double size;
  const PulseDot({super.key, this.color = AppColors.success, this.size = 8});
  @override State<PulseDot> createState() => _PulseDotState();
}
class _PulseDotState extends State<PulseDot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override void initState() { super.initState(); _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(); }
  @override void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) => SizedBox(
        width: widget.size * 2.8, height: widget.size * 2.8,
        child: Stack(alignment: Alignment.center, children: [
          Opacity(
            opacity: (1 - _ctrl.value) * 0.7,
            child: Transform.scale(
              scale: 1 + _ctrl.value * 1.8,
              child: Container(width: widget.size, height: widget.size,
                decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color)),
            ),
          ),
          Container(width: widget.size, height: widget.size,
            decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color,
              boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.6), blurRadius: 8)])),
        ]),
      ),
    );
  }
}

// ─── COUNTDOWN RING ───────────────────────────────────────────────────────────
class CountdownRing extends StatelessWidget {
  final int secondsRemaining, totalSeconds;
  const CountdownRing({super.key, required this.secondsRemaining, required this.totalSeconds});
  @override
  Widget build(BuildContext context) {
    final progress = secondsRemaining / totalSeconds;
    return SizedBox(width: 38, height: 38, child: Stack(alignment: Alignment.center, children: [
      CircularProgressIndicator(
        value: progress, strokeWidth: 2.5,
        backgroundColor: AppColors.border,
        valueColor: AlwaysStoppedAnimation<Color>(
          progress > 0.4 ? AppColors.accent : AppColors.accentPink),
      ),
      Text('$secondsRemaining', style: const TextStyle(color: AppColors.textMuted, fontSize: 10, fontWeight: FontWeight.w700)),
    ]));
  }
}

// ─── ANIMATED STAT VALUE ──────────────────────────────────────────────────────
class AnimatedStatValue extends StatefulWidget {
  final String value;
  final TextStyle style;
  const AnimatedStatValue({super.key, required this.value, required this.style});
  @override State<AnimatedStatValue> createState() => _AnimatedStatValueState();
}
class _AnimatedStatValueState extends State<AnimatedStatValue> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<Color?> _color;
  String _displayed = '';
  @override
  void initState() {
    super.initState();
    _displayed = widget.value;
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _color = ColorTween(begin: AppColors.accentCyan, end: widget.style.color ?? AppColors.textPrimary)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
  }
  @override
  void didUpdateWidget(AnimatedStatValue old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) { _displayed = widget.value; _ctrl.forward(from: 0.0); }
  }
  @override void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(animation: _ctrl,
      builder: (_, child) => Text(_displayed, style: widget.style.copyWith(color: _color.value)));
  }
}

// ─── FROSTED GLASS CARD ───────────────────────────────────────────────────────
class FrostCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final bool glow;
  final Color? glowColor;
  const FrostCard({super.key, required this.child, this.padding = const EdgeInsets.all(20), this.radius = 18, this.glow = false, this.glowColor});
  @override
  Widget build(BuildContext context) {
    final gc = glowColor ?? AppColors.accent;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [AppColors.card.withValues(alpha: 0.85), AppColors.cardGlow.withValues(alpha: 0.6)],
        ),
        border: Border.all(color: glow ? AppColors.borderBright : AppColors.border),
        boxShadow: glow ? [BoxShadow(color: gc.withValues(alpha: 0.18), blurRadius: 28, spreadRadius: 0)] : [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 14)],
      ),
      child: child,
    );
  }
}

// ─── APP ROOT ─────────────────────────────────────────────────────────────────
class WeatherAlertApp extends StatelessWidget {
  const WeatherAlertApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Weather Alert',
      theme: ThemeData(
        scaffoldBackgroundColor: AppColors.bg,
        colorScheme: const ColorScheme.dark(primary: AppColors.accent, surface: AppColors.panel),
        textTheme: const TextTheme(bodyMedium: TextStyle(color: AppColors.textPrimary, fontFamily: 'monospace')),
      ),
      home: const LandingScreen(),
    );
  }
}

// ─── LANDING / WELCOME SCREEN ──────────────────────────────────────────────────
class LandingScreen extends StatefulWidget {
  const LandingScreen({super.key});
  @override State<LandingScreen> createState() => _LandingScreenState();
}

class _LandingScreenState extends State<LandingScreen> with TickerProviderStateMixin {
  late AnimationController _introCtrl;
  late Animation<double> _logoFade;
  late Animation<Offset> _logoSlide;
  late Animation<double> _bodyFade;
  bool _navigating = false;

  static const _features = [
    (Icons.bolt_rounded, 'Real-time alerts', 'Live rain, storm & UV warnings as conditions change'),
    (Icons.travel_explore_rounded, 'Any city, instantly', 'Search worldwide or use your live GPS location'),
    (Icons.checkroom_rounded, 'Smart laundry rack', 'Auto-retract your clothesline before the rain hits'),
    (Icons.sms_outlined, 'SMS & WhatsApp alerts', 'Get texted the moment rain risk spikes or the rack moves'),
  ];

  @override
  void initState() {
    super.initState();
    _introCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
    _logoFade  = CurvedAnimation(parent: _introCtrl, curve: const Interval(0.0, 0.6, curve: Curves.easeOut));
    _logoSlide = Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero)
        .animate(CurvedAnimation(parent: _introCtrl, curve: const Interval(0.0, 0.6, curve: Curves.easeOutCubic)));
    _bodyFade  = CurvedAnimation(parent: _introCtrl, curve: const Interval(0.35, 1.0, curve: Curves.easeOut));
    _introCtrl.forward();
  }

  @override
  void dispose() { _introCtrl.dispose(); super.dispose(); }

  void _getStarted() {
    if (_navigating) return;
    _navigating = true;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 650),
        pageBuilder: (_, anim, _) => const HomeScreen(),
        transitionsBuilder: (_, anim, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: NebulaBackground(
        child: SafeArea(
          child: LayoutBuilder(builder: (context, constraints) {
            final isNarrow = constraints.maxWidth < 560;
            return SingleChildScrollView(
              padding: EdgeInsets.symmetric(horizontal: isNarrow ? 24 : 48, vertical: 32),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(height: isNarrow ? 40 : 72),
                      FadeTransition(
                        opacity: _logoFade,
                        child: SlideTransition(
                          position: _logoSlide,
                          child: Column(children: [
                            Container(
                              width: 92, height: 92,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: const LinearGradient(
                                  colors: [AppColors.accentSoft, AppColors.accentPink],
                                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                                ),
                                boxShadow: [
                                  BoxShadow(color: AppColors.accentSoft.withValues(alpha: 0.55), blurRadius: 40, spreadRadius: 4),
                                ],
                              ),
                              child: const Center(child: Text('✦', style: TextStyle(fontSize: 44, color: Colors.white))),
                            ),
                            const SizedBox(height: 24),
                            Text('Welcome to',
                              style: const TextStyle(color: AppColors.textSub, fontSize: 15, letterSpacing: 2, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            ShaderMask(
                              shaderCallback: (b) => const LinearGradient(
                                colors: [Colors.white, AppColors.accent, AppColors.accentPink],
                              ).createShader(b),
                              child: Text('Weather Alert',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white, fontSize: isNarrow ? 36 : 46, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Your sky, your alerts, your rules —\nreal-time weather with a smart laundry assistant.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppColors.textSub, fontSize: 14, height: 1.6),
                            ),
                          ]),
                        ),
                      ),
                      SizedBox(height: isNarrow ? 32 : 44),
                      FadeTransition(
                        opacity: _bodyFade,
                        child: Column(children: [
                          ..._features.map((f) => Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: FrostCard(
                              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                              child: Row(children: [
                                Container(
                                  width: 44, height: 44,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(13),
                                    color: AppColors.accent.withValues(alpha: 0.14),
                                    border: Border.all(color: AppColors.border),
                                  ),
                                  child: Icon(f.$1, color: AppColors.accent, size: 22),
                                ),
                                const SizedBox(width: 14),
                                Expanded(child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(f.$2, style: const TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 3),
                                    Text(f.$3, style: const TextStyle(color: AppColors.textMuted, fontSize: 12, height: 1.4)),
                                  ],
                                )),
                              ]),
                            ),
                          )),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: GestureDetector(
                              onTap: _getStarted,
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16),
                                  gradient: const LinearGradient(colors: [AppColors.accentSoft, AppColors.accentPink]),
                                  boxShadow: [BoxShadow(color: AppColors.accentSoft.withValues(alpha: 0.45), blurRadius: 26, offset: const Offset(0, 10))],
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: const [
                                    Text('Get Started', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 0.3)),
                                    SizedBox(width: 8),
                                    Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 20),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Text('Free forever · No account needed',
                            style: TextStyle(color: AppColors.textMuted, fontSize: 11.5)),
                        ]),
                      ),
                      SizedBox(height: isNarrow ? 24 : 40),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

// ─── HOME SCREEN ──────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  static const int _refreshIntervalSeconds = 60;

  int _selectedNav = 0;
  WeatherData? _weather;
  bool _loading = true;
  bool _silentFetching = false;
  String _error = '';
  final TextEditingController _searchCtrl = TextEditingController();

  Timer? _countdownTimer;
  int _secondsToRefresh = _refreshIntervalSeconds;
  String _currentCity = 'Manila';
  double? _cachedLat, _cachedLon;
  String? _cachedCityName;

  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800));
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOutCubic);
    _loadWeatherByGPS();
    _startCountdown();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _searchCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _secondsToRefresh = _refreshIntervalSeconds;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() {
        _secondsToRefresh--;
        if (_secondsToRefresh <= 0) {
          _secondsToRefresh = _refreshIntervalSeconds;
          _silentRefresh();
        }
      });
    });
  }

  Future<WeatherData?> _fetchWithRetry(double lat, double lon, String city, {int attempts = 2}) async {
    for (int i = 0; i < attempts; i++) {
      final data = await WeatherService.fetchWeather(lat, lon, city);
      if (data != null) return data;
      if (i < attempts - 1) await Future.delayed(const Duration(seconds: 3));
    }
    return null;
  }

  Future<void> _silentRefresh() async {
    if (_cachedLat == null || _silentFetching) return;
    setState(() => _silentFetching = true);
    try {
      final data = await _fetchWithRetry(_cachedLat!, _cachedLon!, _cachedCityName!);
      if (data != null && mounted) setState(() { _weather = data; _error = ''; });
    } catch (_) {} finally {
      if (mounted) setState(() => _silentFetching = false);
    }
  }

  Future<void> _loadWeatherByGPS() async {
    setState(() { _loading = true; _error = ''; });
    _fadeCtrl.reset();

    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) throw Exception('Location services are disabled');

      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        throw Exception('Location permission denied');
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 12),
        ),
      );

      final label = await WeatherService.reverseGeocode(pos.latitude, pos.longitude)
          ?? '${pos.latitude.toStringAsFixed(2)}, ${pos.longitude.toStringAsFixed(2)}';

      _cachedLat      = pos.latitude;
      _cachedLon      = pos.longitude;
      _cachedCityName = label;
      _currentCity    = label;

      final data = await _fetchWithRetry(_cachedLat!, _cachedLon!, _cachedCityName!);
      if (data == null) throw Exception('Could not load weather data');
      if (!mounted) return;
      setState(() { _weather = data; _loading = false; _silentFetching = false; });
      _fadeCtrl.forward();
      _startCountdown();
    } catch (e) {
      debugPrint('GPS load failed, falling back: $e');
      if (!mounted) return;
      await _loadWeather('Manila', initial: true);
    }
  }

  Future<void> _loadWeather(String city, {bool initial = false}) async {
    setState(() {
      _loading = initial || _weather == null;
      _silentFetching = !initial && _weather != null;
      _error = '';
    });
    _currentCity = city;
    _fadeCtrl.reset();

    try {
      if (_cachedCityName == null || city != _currentCity || _cachedLat == null) {
        final coords = await WeatherService.geocode(city);
        if (coords == null) throw Exception('City "$city" not found');
        _cachedLat      = coords['lat'] as double;
        _cachedLon      = coords['lon'] as double;
        _cachedCityName = '${coords['name']}, ${coords['country']}';
      }

      final data = await _fetchWithRetry(_cachedLat!, _cachedLon!, _cachedCityName!);
      if (data == null) throw Exception('Could not load weather data');
      if (mounted) {
        setState(() { _weather = data; _loading = false; _silentFetching = false; });
        _fadeCtrl.forward();
        _startCountdown();
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString().replaceAll('Exception: ', ''); _loading = false; _silentFetching = false; });
    }
  }

  // ── NAV RAIL ────────────────────────────────────────────────────────────────
  Widget _buildNavRail() {
    final items = [
      (Icons.auto_awesome_rounded, 'Home'),
      (Icons.calendar_view_week_rounded, 'Forecast'),
      (Icons.explore_rounded, 'Map'),
      (Icons.notifications_outlined, 'Alerts'),
      (Icons.checkroom_rounded, 'Laundry'),
    ];
    return Container(
      width: 72,
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [AppColors.panel, AppColors.bg]),
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: Column(children: [
        const SizedBox(height: 18),
        Container(width: 44, height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: const LinearGradient(colors: [AppColors.accentSoft, AppColors.accentPink],
              begin: Alignment.topLeft, end: Alignment.bottomRight),
            boxShadow: [BoxShadow(color: AppColors.accentSoft.withValues(alpha: 0.5), blurRadius: 16)],
          ),
          child: const Center(child: Text('✦', style: TextStyle(fontSize: 22, color: Colors.white))),
        ),
        const SizedBox(height: 24),
        ...List.generate(items.length, (i) {
          final selected = _selectedNav == i;
          return GestureDetector(
            onTap: () => setState(() => _selectedNav = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              width: 56, height: 52,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: selected ? LinearGradient(colors: [AppColors.accentSoft.withValues(alpha: 0.25), AppColors.accent.withValues(alpha: 0.15)]) : null,
                border: selected ? Border.all(color: AppColors.accent.withValues(alpha: 0.45)) : null,
                boxShadow: selected ? [BoxShadow(color: AppColors.accent.withValues(alpha: 0.2), blurRadius: 16)] : [],
              ),
              child: Icon(items[i].$1, color: selected ? AppColors.accent : AppColors.textMuted, size: 22),
            ),
          );
        }),
        const Spacer(),
        Container(margin: const EdgeInsets.only(bottom: 8), child:
          Icon(Icons.settings_outlined, color: AppColors.textMuted, size: 22)),
        Container(
          margin: const EdgeInsets.only(bottom: 20), width: 38, height: 38,
          decoration: BoxDecoration(shape: BoxShape.circle,
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.4), width: 1.5),
            color: AppColors.accent.withValues(alpha: 0.1)),
          child: const Icon(Icons.person_outline_rounded, color: AppColors.accent, size: 18),
        ),
      ]),
    );
  }

  // ── TOP BAR ─────────────────────────────────────────────────────────────────
  Widget _buildTopBar() {
    return Container(
      height: 64,
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [AppColors.panel, AppColors.bg.withValues(alpha: 0.8)]),
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(children: [
        ShaderMask(
          shaderCallback: (b) => const LinearGradient(colors: [AppColors.accent, AppColors.accentPink]).createShader(b),
          child: const Text('Weather Alert', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17, letterSpacing: 0.5)),
        ),
        const SizedBox(width: 24),
        Expanded(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Container(height: 38,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: AppColors.card.withValues(alpha: 0.8),
              border: Border.all(color: AppColors.border),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              Icon(Icons.search_rounded, color: AppColors.textMuted, size: 16),
              const SizedBox(width: 8),
              Expanded(child: TextField(
                controller: _searchCtrl,
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
                decoration: const InputDecoration(
                  hintText: 'Search city…', hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 13),
                  border: InputBorder.none, isDense: true,
                ),
                onSubmitted: (v) { if (v.trim().isNotEmpty) { _cachedLat = null; _loadWeather(v.trim()); }},
              )),
              GestureDetector(
                onTap: () { final v = _searchCtrl.text.trim(); if (v.isNotEmpty) { _cachedLat = null; _loadWeather(v); }},
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    gradient: const LinearGradient(colors: [AppColors.accentSoft, AppColors.accent]),
                  ),
                  child: const Text('Go', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: _loadWeatherByGPS,
                child: Tooltip(
                  message: 'Use my location',
                  child: Container(
                    width: 28, height: 28,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: AppColors.accent.withValues(alpha: 0.12),
                      border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
                    ),
                    child: const Icon(Icons.my_location_rounded, color: AppColors.accent, size: 14),
                  ),
                ),
              ),
            ]),
          ),
        )),
        const Spacer(),
        AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _silentFetching ? AppColors.accentPink.withValues(alpha: 0.4) : AppColors.success.withValues(alpha: 0.35)),
            color: _silentFetching ? AppColors.accentPink.withValues(alpha: 0.08) : AppColors.success.withValues(alpha: 0.08),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            PulseDot(color: _silentFetching ? AppColors.accentPink : AppColors.success, size: 5),
            const SizedBox(width: 6),
            Text(_silentFetching ? 'Updating…' : 'Live',
              style: TextStyle(color: _silentFetching ? AppColors.accentPink : AppColors.success, fontSize: 11, fontWeight: FontWeight.w600)),
          ]),
        ),
        const SizedBox(width: 10),
        if (_weather != null) Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
            color: AppColors.accent.withValues(alpha: 0.08),
          ),
          child: Text('📍 ${_weather!.cityName}', style: const TextStyle(color: AppColors.accent, fontSize: 12)),
        ),
        const SizedBox(width: 12),
        Text(_currentDateStr(), style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: () => _loadWeather(_currentCity),
          child: CountdownRing(secondsRemaining: _secondsToRefresh, totalSeconds: _refreshIntervalSeconds),
        ),
      ]),
    );
  }

  String _currentDateStr() {
    final now = DateTime.now();
    const days   = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${days[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}';
  }

  // ── HERO CARD ───────────────────────────────────────────────────────────────
  Widget _buildHeroCard() {
    final w = _weather!;
    final emoji = w.hourly.isNotEmpty ? w.hourly.first.icon : '🌌';

    return LayoutBuilder(builder: (context, constraints) {
      final isNarrow = constraints.maxWidth < 520;
      final pad      = isNarrow ? 20.0 : 28.0;
      final tempSize = isNarrow ? 64.0 : 80.0;
      final emojiBox = isNarrow ? 72.0 : 96.0;
      final emojiFs  = isNarrow ? 44.0 : 60.0;

      final topRow = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: emojiBox, height: emojiBox,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [AppColors.accentSoft.withValues(alpha: 0.3), Colors.transparent]),
            ),
            child: Center(child: Text(emoji, style: TextStyle(fontSize: emojiFs))),
          ),
          SizedBox(width: isNarrow ? 12 : 24),
          ShaderMask(
            shaderCallback: (b) => const LinearGradient(
              colors: [Colors.white, AppColors.accent, AppColors.accentPink],
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
            ).createShader(b),
            child: AnimatedStatValue(
              value: '${w.temperature.toInt()}°',
              style: TextStyle(fontSize: tempSize, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -4),
            ),
          ),
          if (!isNarrow) const Spacer(),
          if (!isNarrow) Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            CountdownRing(secondsRemaining: _secondsToRefresh, totalSeconds: _refreshIntervalSeconds),
            const SizedBox(height: 4),
            const Text('auto', style: TextStyle(color: AppColors.textMuted, fontSize: 9)),
          ]),
        ],
      );

      final textBlock = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            w.cityName,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: 0.3),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
          const SizedBox(height: 4),
          Text(
            '${w.description} · feels ${w.feelsLike.toInt()}°C',
            style: const TextStyle(color: AppColors.textSub, fontSize: 13),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
          const SizedBox(height: 14),
          Wrap(spacing: 10, runSpacing: 8, children: [
            _statPill('💧', '${w.humidity.toInt()}%', 'Humidity'),
            _statPill('💨', '${w.windSpeed.toInt()} km/h', 'Wind'),
            _statPill('🌂', '${(w.rainChance * 100).toInt()}%', 'Rain'),
            _statPill('☁️', '${w.cloudCover}%', 'Cloud'),
          ]),
        ],
      );

      return Container(
        padding: EdgeInsets.all(pad),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFF1A1040), Color(0xFF0F0A28), Color(0xFF0A0620)],
          ),
          border: Border.all(color: AppColors.borderBright),
          boxShadow: [
            BoxShadow(color: AppColors.accentSoft.withValues(alpha: 0.25), blurRadius: 40, spreadRadius: -5),
            BoxShadow(color: AppColors.accentPink.withValues(alpha: 0.1), blurRadius: 60, offset: const Offset(0, 20)),
          ],
        ),
        child: isNarrow
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                topRow,
                const SizedBox(height: 16),
                textBlock,
              ])
            : Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                Container(
                  width: emojiBox, height: emojiBox,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [AppColors.accentSoft.withValues(alpha: 0.3), Colors.transparent]),
                  ),
                  child: Center(child: Text(emoji, style: TextStyle(fontSize: emojiFs))),
                ),
                const SizedBox(width: 24),
                ShaderMask(
                  shaderCallback: (b) => const LinearGradient(
                    colors: [Colors.white, AppColors.accent, AppColors.accentPink],
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                  ).createShader(b),
                  child: AnimatedStatValue(
                    value: '${w.temperature.toInt()}°',
                    style: TextStyle(fontSize: tempSize, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -4),
                  ),
                ),
                const SizedBox(width: 28),
                Expanded(child: textBlock),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  CountdownRing(secondsRemaining: _secondsToRefresh, totalSeconds: _refreshIntervalSeconds),
                  const SizedBox(height: 4),
                  const Text('auto', style: TextStyle(color: AppColors.textMuted, fontSize: 9)),
                ]),
              ]),
      );
    });
  }

  Widget _statPill(String icon, String value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: AppColors.accent.withValues(alpha: 0.08),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(icon, style: const TextStyle(fontSize: 12)),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
        const SizedBox(width: 4),
        AnimatedStatValue(value: value, style: const TextStyle(color: AppColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  // ── MINI CARDS ──────────────────────────────────────────────────────────────
  Widget _buildMiniCards({bool isNarrow = false}) {
    final w = _weather!;
    final cards = [
      _MiniData('🌡️', '${w.temperature.toInt()}°C', 'Temperature', 'Feels ${w.feelsLike.toInt()}°C', true, AppColors.accentSoft),
      _MiniData('💧', '${w.humidity.toInt()}%', 'Humidity', w.humidity > 80 ? '⚠️ Very humid' : 'Comfortable', w.humidity <= 70, AppColors.accentCyan),
      _MiniData('☀️', 'UV ${w.uvIndex}', 'UV Index', w.uvIndex >= 8 ? '⚠️ High risk' : 'Moderate', w.uvIndex < 6, AppColors.accentGold),
      _MiniData('👁️', '${w.visibility.toStringAsFixed(0)} km', 'Visibility', w.visibility >= 10 ? '✦ Clear' : '↓ Reduced', w.visibility >= 10, AppColors.success),
    ];

    Widget buildCard(_MiniData c) => FrostCard(
      glow: true, glowColor: c.accent,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Container(width: 40, height: 40,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: c.accent.withValues(alpha: 0.15)),
          child: Center(child: Text(c.icon, style: const TextStyle(fontSize: 20))),
        ),
        const SizedBox(height: 12),
        AnimatedStatValue(value: c.value, style: const TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(c.label, style: const TextStyle(color: AppColors.textMuted, fontSize: 11, letterSpacing: 0.5)),
        const SizedBox(height: 6),
        Text(c.trend, style: TextStyle(color: c.trendUp ? AppColors.success : AppColors.warning, fontSize: 11)),
      ]),
    );

    if (isNarrow) {
      return Column(children: [
        Row(children: [
          Expanded(child: buildCard(cards[0])),
          const SizedBox(width: 12),
          Expanded(child: buildCard(cards[1])),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: buildCard(cards[2])),
          const SizedBox(width: 12),
          Expanded(child: buildCard(cards[3])),
        ]),
      ]);
    }

    return Row(children: cards.asMap().entries.map((e) {
      final c = e.value;
      final isLast = e.key == cards.length - 1;
      return Expanded(child: Container(
        margin: EdgeInsets.only(right: isLast ? 0 : 14),
        child: buildCard(c),
      ));
    }).toList());
  }

  // ── HOURLY FORECAST ─────────────────────────────────────────────────────────
  Widget _buildHourlyForecast() {
    final hourly = _weather!.hourly;
    return FrostCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionLabel('HOURLY FORECAST'),
      const SizedBox(height: 16),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: hourly.map((h) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.only(right: 10),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: h.isNow ? LinearGradient(colors: [AppColors.accentSoft.withValues(alpha: 0.25), AppColors.accent.withValues(alpha: 0.12)]) : null,
              color: h.isNow ? null : AppColors.bg.withValues(alpha: 0.5),
              border: Border.all(color: h.isNow ? AppColors.accent.withValues(alpha: 0.55) : AppColors.border),
              boxShadow: h.isNow ? [BoxShadow(color: AppColors.accent.withValues(alpha: 0.2), blurRadius: 20)] : [],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(h.time, style: TextStyle(color: h.isNow ? AppColors.accent : AppColors.textMuted, fontSize: 11, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(h.icon, style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 6),
              AnimatedStatValue(value: '${h.temp}°', style: TextStyle(
                color: h.isNow ? AppColors.accent : AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              SizedBox(
                width: 42,
                height: 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: h.rain,
                    minHeight: 3,
                    backgroundColor: AppColors.border,
                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.accentCyan.withValues(alpha: 0.7)),
                  ),
                ),
              ),
            ]),
          );
        }).toList()),
      ),
    ]));
  }

  // ── WEEKLY FORECAST ─────────────────────────────────────────────────────────
  Widget _buildWeeklyForecast() {
    final daily = _weather!.daily;
    return FrostCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionLabel('7-DAY FORECAST'),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, constraints) {
        final isTight = constraints.maxWidth < 280;
        final dayW    = isTight ? 34.0 : 48.0;
        final barW    = isTight ? 44.0 : 90.0;
        final showDesc = constraints.maxWidth > 220;

        return Column(children: daily.asMap().entries.map((e) {
          final d = e.value;
          final isLast = e.key == daily.length - 1;
          final isToday = e.key == 0;
          return Column(children: [
            Container(
              padding: isToday ? const EdgeInsets.symmetric(vertical: 6, horizontal: 8) : EdgeInsets.zero,
              decoration: isToday ? BoxDecoration(borderRadius: BorderRadius.circular(10), color: AppColors.accent.withValues(alpha: 0.07)) : null,
              child: Row(children: [
                SizedBox(
                  width: dayW,
                  child: Text(
                    d.day,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: isToday ? AppColors.accent : AppColors.textSub, fontSize: 13, fontWeight: isToday ? FontWeight.w700 : FontWeight.normal),
                  ),
                ),
                Text(d.icon, style: const TextStyle(fontSize: 17)),
                const SizedBox(width: 8),
                if (showDesc)
                  Expanded(
                    child: Text(
                      d.desc,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                    ),
                  )
                else
                  const Spacer(),
                const SizedBox(width: 8),
                SizedBox(
                  width: barW,
                  height: 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: d.rainPct,
                      backgroundColor: AppColors.border,
                      valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text('${d.min}°', style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                const SizedBox(width: 6),
                Text('${d.max}°', style: const TextStyle(color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w700)),
              ]),
            ),
            if (!isLast) Divider(color: AppColors.border.withValues(alpha: 0.6), height: 18),
          ]);
        }).toList());
      }),
    ]));
  }

  // ── ADVICE CARD ─────────────────────────────────────────────────────────────
  Widget _buildAdviceCard() {
    final w = _weather!;
    final isHighRisk = w.rainChance >= 0.7;
    final advice = _generateAdvice(w);
    final col = isHighRisk ? AppColors.accentPink : AppColors.accent;
    return FrostCard(glow: true, glowColor: col,
      child: Row(children: [
        Container(width: 48, height: 48,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: col.withValues(alpha: 0.15),
            border: Border.all(color: col.withValues(alpha: 0.3))),
          child: Center(child: Icon(isHighRisk ? Icons.thunderstorm_outlined : Icons.wb_sunny_outlined, color: col, size: 24)),
        ),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(isHighRisk ? 'Storm Advisory' : 'Weather Brief',
            style: TextStyle(color: col, fontWeight: FontWeight.w800, fontSize: 14, letterSpacing: 0.3)),
          const SizedBox(height: 6),
          Text(advice, style: const TextStyle(color: AppColors.textSub, fontSize: 13, height: 1.5)),
        ])),
      ]),
    );
  }

  String _generateAdvice(WeatherData w) {
    final parts = <String>[];
    if (w.rainChance >= 0.7) {
      parts.add('⚠️ High rain (${(w.rainChance * 100).toInt()}%) — bring an umbrella.');
    } else if (w.rainChance >= 0.4) {
      parts.add('🌂 Moderate rain (${(w.rainChance * 100).toInt()}%) — umbrella recommended.');
    }
    if (w.uvIndex >= 8) parts.add('☀️ Very high UV (${w.uvIndex}) — wear sunscreen.');
    if (w.humidity > 80) parts.add('💧 High humidity (${w.humidity.toInt()}%) — stay hydrated.');
    if (w.temperature >= 35) parts.add('🌡️ Extreme heat — limit outdoor exposure.');
    if (parts.isEmpty) parts.add('✦ Conditions are favourable today. Enjoy the cosmos!');
    return parts.join('  ');
  }

  Widget _sectionLabel(String label) => Text(label,
    style: const TextStyle(color: AppColors.textMuted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.4));

  // ── LOADING / ERROR ─────────────────────────────────────────────────────────
  Widget _buildLoadingState() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const WaveShimmer(height: 160, radius: 24),
        const SizedBox(height: 20),
        Row(children: List.generate(4, (i) => Expanded(
          child: Container(margin: EdgeInsets.only(right: i < 3 ? 14 : 0), child: const WaveShimmer(height: 110)),
        ))),
        const SizedBox(height: 20),
        const Row(children: [
          Expanded(child: WaveShimmer(height: 140)),
          SizedBox(width: 16),
          Expanded(child: WaveShimmer(height: 140)),
        ]),
      ]),
    );
  }

  Widget _buildErrorState() {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('✦', style: TextStyle(fontSize: 56, color: AppColors.accentPink)),
      const SizedBox(height: 16),
      Text(_error, style: const TextStyle(color: AppColors.accentPink, fontSize: 14), textAlign: TextAlign.center),
      const SizedBox(height: 20),
      GestureDetector(
        onTap: () => _loadWeather(_currentCity),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: const LinearGradient(colors: [AppColors.accentSoft, AppColors.accentPink]),
            boxShadow: [BoxShadow(color: AppColors.accentSoft.withValues(alpha: 0.4), blurRadius: 20)],
          ),
          child: const Text('Try Again', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        ),
      ),
    ]));
  }

  // ── DASHBOARD ───────────────────────────────────────────────────────────────
  Widget _buildDashboard() {
    if (_loading) return _buildLoadingState();
    if (_error.isNotEmpty && _weather == null) return _buildErrorState();
    if (_weather == null) return _buildLoadingState();

    return LayoutBuilder(builder: (context, constraints) {
      final isNarrow = constraints.maxWidth < 600;
      final pad = isNarrow ? 14.0 : 24.0;

      final Widget forecasts = isNarrow
          ? Column(children: [
              _buildHourlyForecast(),
              const SizedBox(height: 16),
              _buildWeeklyForecast(),
            ])
          : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _buildHourlyForecast()),
              const SizedBox(width: 16),
              Expanded(child: _buildWeeklyForecast()),
            ]);

      final staleSeconds = DateTime.now().difference(_weather!.fetchedAt).inSeconds;
      final isStale = staleSeconds > 90;

      return FadeTransition(
        opacity: _fadeAnim,
        child: SingleChildScrollView(
          padding: EdgeInsets.all(pad),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              PulseDot(color: _silentFetching ? AppColors.accentPink : AppColors.success, size: 5),
              const SizedBox(width: 8),
              Flexible(child: Text(
                _silentFetching ? 'Syncing with satellite…' : 'Live data · Open-Meteo · updated ${staleSeconds}s ago',
                style: TextStyle(color: isStale ? AppColors.warning : AppColors.textMuted, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              )),
              const Spacer(),
              Text('Refresh in ${_secondsToRefresh}s', style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
            ]),
            const SizedBox(height: 14),
            _buildHeroCard(),
            const SizedBox(height: 20),
            _buildMiniCards(isNarrow: isNarrow),
            const SizedBox(height: 20),
            forecasts,
            const SizedBox(height: 20),
            _buildAdviceCard(),
            const SizedBox(height: 20),
          ]),
        ),
      );
    });
  }

  // ── MAIN BUILD ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final isWide   = constraints.maxWidth > 900;
      final isMedium = constraints.maxWidth > 600;

      if (isWide) {
        return Scaffold(
          backgroundColor: AppColors.bg,
          body: NebulaBackground(child: Row(children: [
            _buildNavRail(),
            Expanded(child: Column(children: [
              _buildTopBar(),
              Expanded(child: Row(children: [
                Expanded(child: _selectedNav == 4 ? LaundryScreen(weather: _weather) : _buildDashboard()),
                if (_selectedNav != 4) ...[
                  Container(width: 1, color: AppColors.border),
                  SizedBox(width: 340, child: LaundryControlPanel(weather: _weather)),
                ],
              ])),
            ])),
          ])),
        );
      }

      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          backgroundColor: AppColors.panel,
          elevation: 0,
          title: isMedium ? _buildCompactSearch() : ShaderMask(
            shaderCallback: (b) => const LinearGradient(colors: [AppColors.accent, AppColors.accentPink]).createShader(b),
            child: const Text('Weather Alert', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
          ),
          actions: [
            if (_weather != null) Padding(padding: const EdgeInsets.only(right: 4),
              child: Center(child: PulseDot(color: _silentFetching ? AppColors.accentPink : AppColors.success, size: 5))),
            Padding(padding: const EdgeInsets.only(right: 10),
              child: CountdownRing(secondsRemaining: _secondsToRefresh, totalSeconds: _refreshIntervalSeconds)),
          ],
        ),
        body: NebulaBackground(child: Column(children: [
          if (!isMedium) Container(color: AppColors.panel.withValues(alpha: 0.9),
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: _buildCompactSearch()),
          Container(height: 1, color: AppColors.border),
          Expanded(child: _selectedNav == 4 ? LaundryControlPanel(weather: _weather) : _buildDashboard()),
        ])),
        bottomNavigationBar: _buildBottomNav(),
      );
    });
  }

  Widget _buildCompactSearch() {
    return Container(height: 36,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: AppColors.card, border: Border.all(color: AppColors.border)),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(children: [
        const Icon(Icons.search_rounded, color: AppColors.textMuted, size: 14),
        const SizedBox(width: 6),
        Expanded(child: TextField(
          controller: _searchCtrl,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
          decoration: const InputDecoration(hintText: 'Search city…', hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 13), border: InputBorder.none, isDense: true),
          onSubmitted: (v) { if (v.trim().isNotEmpty) { _cachedLat = null; _loadWeather(v.trim()); }},
        )),
        GestureDetector(
          onTap: _loadWeatherByGPS,
          child: Container(
            width: 24, height: 24,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              color: AppColors.accent.withValues(alpha: 0.12),
              border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
            ),
            child: const Icon(Icons.my_location_rounded, color: AppColors.accent, size: 13),
          ),
        ),
      ]),
    );
  }

  Widget _buildBottomNav() {
    final items = [(Icons.auto_awesome_rounded, 'Home'), (Icons.calendar_view_week_rounded, 'Forecast'), (Icons.explore_rounded, 'Map'), (Icons.notifications_outlined, 'Alerts'), (Icons.checkroom_rounded, 'Laundry')];
    return Container(
      decoration: BoxDecoration(color: AppColors.panel, border: Border(top: BorderSide(color: AppColors.border))),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: items.asMap().entries.map((e) {
        final selected = _selectedNav == e.key;
        return GestureDetector(
          onTap: () => setState(() => _selectedNav = e.key),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(e.value.$1, color: selected ? AppColors.accent : AppColors.textMuted, size: 22),
              const SizedBox(height: 3),
              Text(e.value.$2, style: TextStyle(color: selected ? AppColors.accent : AppColors.textMuted, fontSize: 10, fontWeight: selected ? FontWeight.w700 : FontWeight.normal)),
            ]),
          ),
        );
      }).toList()),
    );
  }
}

// ─── DATA HELPERS ─────────────────────────────────────────────────────────────
class _MiniData {
  final String icon, value, label, trend;
  final bool trendUp;
  final Color accent;
  _MiniData(this.icon, this.value, this.label, this.trend, this.trendUp, this.accent);
}

// ─── ESP32 SERVICE (Laundry Rack + Fan Controller) ────────────────────────────
class ESP32Service {
  // FIX #7: hostname advertised by the firmware via mDNS. Resolving this
  // instead of a hard-coded IP means DHCP can hand the ESP32 a different
  // address after every reboot and the app still finds it.
  static const String mdnsHost = 'laundry.local';

  /// Cheap liveness probe used by discovery. Deliberately short-timeout:
  /// a scan fires this ~254 times, so 6s each would take forever.
  static Future<bool> probe(String host, {Duration timeout = const Duration(milliseconds: 900)}) async {
    if (host.isEmpty) return false;
    try {
      final res = await http.get(Uri.parse('http://$host/status')).timeout(timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static bool looksLikeIp(String s) {
    final parts = s.split('.');
    if (parts.length != 4) return false;
    return parts.every((p) {
      final n = int.tryParse(p);
      return n != null && n >= 0 && n <= 255;
    });
  }

  static String? _subnetOf(String ip) {
    if (!looksLikeIp(ip)) return null;
    final p = ip.split('.');
    return '${p[0]}.${p[1]}.${p[2]}';
  }

  // FIX #8: batch size and timeouts tuned to the firmware's actual pace.
  // loop() runs server.handleClient() once per pass with a delay(100), so
  // the ESP32 answers roughly one request every ~110ms and its TCP backlog
  // is tiny. Firing 32 probes at once simply overflowed it and the real
  // device timed out along with the empty addresses. 8 at a time with a
  // 1.5s window gives each probe several chances to be serviced.
  static Future<String?> discover({
    String? subnetSeed,
    void Function(String)? onProgress,
    bool allowScan = true,
  }) async {
    onProgress?.call('Looking for $mdnsHost…');
    if (await probe(mdnsHost, timeout: const Duration(seconds: 3))) return mdnsHost;

    if (!allowScan) return null;
    final subnet = subnetSeed == null ? null : _subnetOf(subnetSeed);
    if (subnet == null) return null;

    const batchSize = 8;
    for (int start = 1; start <= 254; start += batchSize) {
      final end = math.min(start + batchSize - 1, 254);
      onProgress?.call('Scanning $subnet.$start–$end…');
      final hosts = [for (int i = start; i <= end; i++) '$subnet.$i'];
      final results = await Future.wait(hosts.map(
        (h) async => (host: h, ok: await probe(h, timeout: const Duration(milliseconds: 1500))),
      ));
      for (final r in results) {
        if (r.ok) return r.host;
      }
    }
    return null;
  }

  static Future<({bool success, String? message})> _command(String host, String path) async {
    if (host.isEmpty) return (success: false, message: null);
    final url = Uri.parse('http://$host$path');
    try {
      final res = await http.get(url).timeout(const Duration(seconds: 6));
      String? msg;
      try {
        final body = jsonDecode(res.body);
        if (body is Map && body['message'] != null) msg = body['message'].toString();
      } catch (_) {}
      return (success: res.statusCode == 200, message: msg);
    } catch (e) {
      debugPrint('ESP32Service error ($path): $e');
      return (success: false, message: null);
    }
  }

  static Future<({bool success, String? message})> extractClothes(String host) => _command(host, '/extract');
  static Future<({bool success, String? message})> retractClothes(String host) => _command(host, '/retract');
  static Future<({bool success, String? message})> fanOn(String host)          => _command(host, '/fan/on');
  static Future<({bool success, String? message})> fanOff(String host)         => _command(host, '/fan/off');

  // FIX #2 (Dart side): calibration command so the app can correct the
  // firmware's stored position when it and reality disagree (e.g. right
  // after a power-cycle before the persisted-position firmware fix has
  // ever run once, or after a manual hand-move of the rack).
  static Future<({bool success, String? message})> calibrate(String host, String position) =>
      _command(host, '/calibrate?position=$position');

  static Future<Map<String, dynamic>?> fetchStatus(String host) async {
    if (host.isEmpty) return null;
    final url = Uri.parse('http://$host/status');
    try {
      final res = await http.get(url).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('ESP32Service status error: $e');
      return null;
    }
  }
}

// ─── TWILIO SERVICE (SMS / WhatsApp notifications) ────────────────────────────

// FIX #5: TwilioConfig now performs real pre-flight validation instead of
// just checking for non-empty strings. The original `isValid` happily
// accepted From == To, which Twilio rejects outright with error 21266 —
// the exact failure seen in the UI screenshot. Each rule below maps to a
// concrete Twilio rejection, so we catch it locally and explain it in
// plain language rather than burning a round-trip on a guaranteed failure.
class TwilioConfig {
  final String accountSid, authToken, fromNumber, toNumber;
  final bool useWhatsapp;
  const TwilioConfig({
    required this.accountSid,
    required this.authToken,
    required this.fromNumber,
    required this.toNumber,
    required this.useWhatsapp,
  });

  static final _e164 = RegExp(r'^\+[1-9]\d{7,14}$');

  /// null = looks sendable. Otherwise a human-readable reason.
  String? get validationError {
    final sid   = accountSid.trim();
    final token = authToken.trim();
    final from  = fromNumber.trim();
    final to    = toNumber.trim();

    if (sid.isEmpty || token.isEmpty || from.isEmpty || to.isEmpty) {
      return 'Fill in all four fields first.';
    }
    if (!sid.startsWith('AC') || sid.length != 34) {
      return 'Account SID should start with "AC" and be 34 characters long.';
    }
    if (!_e164.hasMatch(from)) {
      return 'From number must be E.164 format, e.g. +14155238886';
    }
    if (!_e164.hasMatch(to)) {
      return 'Your number must be E.164 format, e.g. +639171234567';
    }
    if (from == to) {
      return 'From and To cannot be the same number (Twilio error 21266). '
             'From = your Twilio / WhatsApp-sandbox number. To = your own phone.';
    }
    return null;
  }

  bool get isValid => validationError == null;
}

typedef TwilioResult = ({bool success, String? error});

// FIX #5: sendMessage no longer collapses every failure into a bare
// `false`. Twilio always explains itself in the response body — we now
// surface that code and message, translate the common ones into
// actionable advice, and special-case the Flutter-web CORS wall (which
// silently blocks every request no matter how good the credentials are).
class TwilioService {
  static Future<TwilioResult> sendMessage(TwilioConfig cfg, String body) async {
    final invalid = cfg.validationError;
    if (invalid != null) return (success: false, error: invalid);

    final sid    = cfg.accountSid.trim();
    final token  = cfg.authToken.trim();
    final url    = Uri.parse('https://api.twilio.com/2010-04-01/Accounts/$sid/Messages.json');
    final prefix = cfg.useWhatsapp ? 'whatsapp:' : '';
    final auth   = base64Encode(utf8.encode('$sid:$token'));

    try {
      final res = await http.post(
        url,
        headers: {
          'Authorization': 'Basic $auth',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: {
          'From': '$prefix${cfg.fromNumber.trim()}',
          'To':   '$prefix${cfg.toNumber.trim()}',
          'Body': body,
        },
      ).timeout(const Duration(seconds: 15));

      if (res.statusCode == 200 || res.statusCode == 201) {
        return (success: true, error: null);
      }

      String detail = 'HTTP ${res.statusCode}';
      try {
        final d = jsonDecode(res.body);
        if (d is Map && d['message'] != null) {
          detail = d['code'] != null ? '${d['code']}: ${d['message']}' : '${d['message']}';
        }
      } catch (_) {}
      return (success: false, error: _explain(detail, res.statusCode));
    } on TimeoutException {
      return (success: false, error: 'Timed out reaching Twilio — check your internet connection.');
    } catch (e) {
      if (kIsWeb) {
        return (success: false, error:
          'Blocked by the browser (CORS). api.twilio.com sends no CORS headers, so '
          'Flutter web can never call it directly. Run on Android / iOS / desktop, '
          'or route the call through your own backend.');
      }
      debugPrint('TwilioService error: $e');
      return (success: false, error: e.toString());
    }
  }

  static String _explain(String detail, int status) {
    if (status == 401) {
      return '401: Authentication failed — Account SID or Auth Token is wrong.';
    }
    const hints = {
      '21266': 'From and To must be different numbers.',
      '21211': '"Your Number" is not a valid phone number.',
      '21608': 'Trial account — verify this number under Phone Numbers → Verified Caller IDs.',
      '21606': 'That From number can\'t send on your account.',
      '21212': 'That From number is not a valid Twilio sender.',
      '63007': 'WhatsApp: the From number isn\'t a WhatsApp sender. Use the sandbox '
               'number shown in your Twilio Console.',
      '63016': 'WhatsApp sandbox: send "join <your-code>" to the sandbox number from '
               'your own phone first. Opt-in expires after 72h of inactivity.',
      '63015': 'WhatsApp sandbox: opt-in required or expired — re-send the join code.',
      '63003': 'WhatsApp: the To number has no WhatsApp account.',
    };
    for (final e in hints.entries) {
      if (detail.startsWith(e.key)) return '$detail\n→ ${e.value}';
    }
    return detail;
  }
}

// ─── LAUNDRY CONTROL PANEL (talks to the ESP32) ───────────────────────────────
class LaundryControlPanel extends StatefulWidget {
  final WeatherData? weather;
  const LaundryControlPanel({super.key, this.weather});
  @override State<LaundryControlPanel> createState() => _LaundryControlPanelState();
}

class _LaundryControlPanelState extends State<LaundryControlPanel> with SingleTickerProviderStateMixin {
  final TextEditingController _ipCtrl = TextEditingController();
  bool _connected      = false;
  bool _checkingConn   = false;
  bool _extended       = false; // true = clothes are out to dry, false = retracted
  bool _fanOn          = false;
  bool _busy           = false;
  String _statusMsg    = 'Select your ESP32 from the list and tap Connect.';
  // FIX: track whether the last _statusMsg represents success/failure/neutral
  // so the UI can color it instead of everything looking the same.
  _StatusTone _statusTone = _StatusTone.neutral;
  bool _calibrating = false;

  bool _motorRunning     = false;
  String _motorDirection = 'stopped';
  int? _rainValue;
  int? _mq135Value;
  bool _mq135WarmingUp = false; // FIX: mirrors firmware warm-up flag
  int _connFailCount = 0;
  bool _connectionLostNotified = false;

  late AnimationController _glowCtrl;
  late Animation<double> _glowAnim;

  // FIX #7: the mDNS name sits at the top of the list so it's the default
  // pick — it survives DHCP handing out a new IP, which the raw addresses
  // below do not.
  final List<String> _savedDevices = [ESP32Service.mdnsHost, '192.168.1.50', '192.168.4.1'];
  String? _selectedDevice;
  bool _showCustomInput = false;
  bool _discovering = false;
  final TextEditingController _customIpCtrl = TextEditingController();

  final List<_ChatMessage> _chatMessages = [];
  final TextEditingController _chatInputCtrl = TextEditingController();
  final ScrollController _chatScrollCtrl = ScrollController();
  static const double _rainAlertThreshold = 0.6;
  bool _highRainAlertActive = false;

  Timer? _statusPollTimer;
  static const Duration _statusPollInterval = Duration(seconds: 5);
  bool _smokeAlertActive = false;
  bool _smokeDetected = false;

  bool _rainSensorAlertActive = false;
  bool _rainSensorDetected = false;

  Timer? _reminderTimer;
  static const Duration _reminderInterval = Duration(hours: 1);

  final TextEditingController _twilioSidCtrl   = TextEditingController();
  final TextEditingController _twilioTokenCtrl = TextEditingController();
  final TextEditingController _twilioFromCtrl  = TextEditingController();
  final TextEditingController _twilioToCtrl    = TextEditingController();
  bool _twilioEnabled      = false;
  bool _twilioUseWhatsapp  = false;
  // FIX #6: no manual send. Alerts fire automatically from _notifyTwilio
  // whenever the rack moves, the fan toggles, or a sensor trips. This log
  // is how you confirm it's working — there's nothing to press.
  String _twilioStatusMsg  = 'Fill in your credentials and flip the switch. Alerts then send on their own — no button to press.';
  final List<({DateTime at, String text, bool ok})> _twilioLog = [];
  static const int _twilioLogMax = 6;
  // FIX #5: the Twilio status line gets its own tone so failures show red
  // and successes show green, instead of every outcome looking identical.
  _StatusTone _twilioTone  = _StatusTone.neutral;
  DateTime? _lastTwilioSentAt;

  @override
  void initState() {
    super.initState();
    _glowCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800))..repeat(reverse: true);
    _glowAnim = Tween<double>(begin: 0.2, end: 0.7).animate(CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut));

    _selectedDevice = _savedDevices.first;
    _ipCtrl.text = _selectedDevice!;

    _chatMessages.add(_ChatMessage.bot(
      'Hi! I\'m your laundry assistant. I watch the rain chance from the weather API, and your ESP32\'s rain and smoke sensors — I\'ll ping you here the moment any of them need your attention. When the ESP32\'s own rain sensor trips, I\'ll ask whether you want the fan on to help air things out. Plus a reminder every hour if rain risk stays high. Turn on Twilio alerts below and I\'ll text or WhatsApp you the same updates — including whenever the rack extracts/retracts or the fan is switched on/off.\n\nIf Extract/Retract ever seem stuck or "already" in a position that looks wrong, use the Calibrate buttons below the rack controls to manually tell me where the rack really is — there\'s no physical limit switch, so occasionally the ESP32 and reality can disagree after a power blip.',
    ));

    _checkRainAndNotify(null, widget.weather);
    _startStatusPolling();
    _startReminderTimer();
  }

  @override
  void didUpdateWidget(covariant LaundryControlPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _checkRainAndNotify(oldWidget.weather, widget.weather);
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    _glowCtrl.dispose();
    _chatInputCtrl.dispose();
    _chatScrollCtrl.dispose();
    _customIpCtrl.dispose();
    _twilioSidCtrl.dispose();
    _twilioTokenCtrl.dispose();
    _twilioFromCtrl.dispose();
    _twilioToCtrl.dispose();
    _statusPollTimer?.cancel();
    _reminderTimer?.cancel();
    super.dispose();
  }

  String get _host => _ipCtrl.text.trim();

  TwilioConfig get _twilioConfig => TwilioConfig(
    accountSid: _twilioSidCtrl.text.trim(),
    authToken: _twilioTokenCtrl.text.trim(),
    fromNumber: _twilioFromCtrl.text.trim(),
    toNumber: _twilioToCtrl.text.trim(),
    useWhatsapp: _twilioUseWhatsapp,
  );

  // FIX #6: this is now the ONLY path that sends. Every call site is an
  // automatic trigger — rack extract/retract, fan on/off, rain-chance
  // spike, hourly reminder, ESP32 rain sensor, smoke sensor. Each outcome
  // is appended to _twilioLog so the panel shows what actually went out.
  void _logTwilio(String text, bool ok) {
    _twilioLog.insert(0, (at: DateTime.now(), text: text, ok: ok));
    if (_twilioLog.length > _twilioLogMax) _twilioLog.removeLast();
  }

  Future<void> _notifyTwilio(String message) async {
    if (!_twilioEnabled) return;
    final cfg = _twilioConfig;
    final invalid = cfg.validationError;
    if (invalid != null) {
      if (mounted) {
        setState(() {
          _twilioStatusMsg = '⚠️ Alert not sent — $invalid';
          _twilioTone = _StatusTone.error;
          _logTwilio(message, false);
        });
      }
      return;
    }
    final r = await TwilioService.sendMessage(cfg, message);
    if (!mounted) return;
    setState(() {
      final channel = cfg.useWhatsapp ? 'WhatsApp' : 'SMS';
      if (r.success) {
        _lastTwilioSentAt = DateTime.now();
        _twilioStatusMsg = '📲 $channel alert sent automatically.';
        _twilioTone = _StatusTone.success;
      } else {
        _twilioStatusMsg = '⚠️ $channel alert failed — ${r.error}';
        _twilioTone = _StatusTone.error;
      }
      _logTwilio(message, r.success);
    });
  }

  void _checkRainAndNotify(WeatherData? oldWeather, WeatherData? newWeather) {
    if (newWeather == null) return;
    final highRainNow = newWeather.rainChance >= _rainAlertThreshold;

    if (highRainNow && !_highRainAlertActive) {
      _highRainAlertActive = true;
      _addRainAlert(newWeather);
    } else if (!highRainNow && _highRainAlertActive) {
      _highRainAlertActive = false;
    }
  }

  void _addRainAlert(WeatherData w) {
    final pct = (w.rainChance * 100).toInt();
    setState(() {
      _chatMessages.add(_ChatMessage.bot(
        '🌧️ Heads up — rain chance just hit $pct% in ${w.cityName}. Do you want to keep your clothes outside, or should I bring them into the garage now?',
        [
          _ChatQuickAction('Keep outside', _handleKeepOutside),
          _ChatQuickAction('Bring inside now', _handleBringInside),
        ],
      ));
    });
    _scrollChatToBottom();
    _notifyTwilio('🌧️ Weather Alert: Rain chance just hit $pct% in ${w.cityName}. Reply in the app to keep clothes outside or bring them in.');
  }

  void _handleKeepOutside() {
    setState(() {
      _chatMessages.add(_ChatMessage.user('Keep outside'));
      _chatMessages.add(_ChatMessage.bot(
        'Okay, leaving them out there for now. I\'ll let you know if the rain risk keeps climbing.',
      ));
    });
    _scrollChatToBottom();
  }

  Future<void> _handleBringInside() async {
    setState(() => _chatMessages.add(_ChatMessage.user('Bring inside now')));
    await _retract();
    setState(() {
      _chatMessages.add(_ChatMessage.bot(
        _connected
            ? '🏠 Got it — retracting the rack into the garage now.'
            : '⚠️ I tried to retract the rack, but couldn\'t reach the ESP32. Check the connection above and try again.',
      ));
    });
    _scrollChatToBottom();
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollCtrl.hasClients) {
        _chatScrollCtrl.animateTo(
          _chatScrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _startReminderTimer() {
    _reminderTimer?.cancel();
    _reminderTimer = Timer.periodic(_reminderInterval, (_) => _sendPeriodicRainReminderIfNeeded());
  }

  void _sendPeriodicRainReminderIfNeeded() {
    final w = widget.weather;
    if (w == null || w.rainChance < _rainAlertThreshold) return;
    final pct = (w.rainChance * 100).toInt();
    setState(() {
      _chatMessages.add(_ChatMessage.bot(
        '⏰ Reminder: rain chance is still high ($pct%) in ${w.cityName}. Keep clothes outside, or bring them into the garage now?',
        [
          _ChatQuickAction('Keep outside', _handleKeepOutside),
          _ChatQuickAction('Bring inside now', _handleBringInside),
        ],
      ));
    });
    _scrollChatToBottom();
    _notifyTwilio('⏰ Weather Alert reminder: rain chance is still high ($pct%) in ${w.cityName}.');
  }

  void _startStatusPolling() {
    _statusPollTimer?.cancel();
    _statusPollTimer = Timer.periodic(_statusPollInterval, (_) => _pollStatus());
  }

  Future<void> _pollStatus() async {
    if (_host.isEmpty) return;
    final status = await ESP32Service.fetchStatus(_host);
    if (!mounted) return;

    if (status == null) {
      _connFailCount++;
      if (_connFailCount >= 2 && _connected) {
        setState(() => _connected = false);
        if (!_connectionLostNotified) {
          _connectionLostNotified = true;
          setState(() => _chatMessages.add(_ChatMessage.bot(
            '⚠️ Lost connection to the ESP32 — I\'ll keep retrying every ${_statusPollInterval.inSeconds}s.',
          )));
          _scrollChatToBottom();
        }
      }
      return;
    }

    if (_connectionLostNotified) {
      _connectionLostNotified = false;
      setState(() => _chatMessages.add(_ChatMessage.bot('✅ Reconnected to the ESP32.')));
      _scrollChatToBottom();
    }

    // FIX #9: the firmware's automaticSensorControl() moves the rack on its
    // own — retracting when rain/smoke trips and extending again once both
    // clear. Those moves never pass through _extract()/_retract(), so they
    // used to update the UI silently with no alert. Compare the polled
    // position against what we last knew and announce the difference.
    // Guarded on _connected (so the first successful poll after connecting
    // isn't reported as a "move") and on !_busy (so a move we commanded
    // ourselves isn't announced twice).
    final hadKnownState = _connected;
    final wasExtended   = _extended;
    final nowExtended   = status['extended'] == true;
    final firmwareMoved = hadKnownState && !_busy && nowExtended != wasExtended;

    _connFailCount = 0;

    setState(() {
      _connected      = true;
      _extended       = nowExtended;
      _fanOn          = status['fan'] == true;
      _motorRunning   = status['motorRunning'] == true;
      _motorDirection = (status['motorDirection'] ?? 'stopped').toString();
      // FIX #9: the firmware key is "smokeSensorWarmingUp". We accept the
      // older "mq135WarmingUp" spelling too so either build works.
      _mq135WarmingUp = status['smokeSensorWarmingUp'] == true || status['mq135WarmingUp'] == true;
      if (status['rainValue'] is num) _rainValue = (status['rainValue'] as num).toInt();
      if (status['mq135Value'] is num) _mq135Value = (status['mq135Value'] as num).toInt();
    });

    if (firmwareMoved) {
      final msg = nowExtended
          ? '☀️ Weather Alert: Sensors cleared — the rack extended itself, clothes are back outside.'
          : '🏠 Weather Alert: Rain or smoke detected — the rack retracted itself, clothes are indoors.';
      setState(() => _chatMessages.add(_ChatMessage.bot(
        nowExtended
            ? '☀️ The ESP32 moved the rack back out on its own — both sensors are clear again.'
            : '🏠 The ESP32 retracted the rack on its own after a sensor tripped. Your clothes are inside.',
      )));
      _scrollChatToBottom();
      _notifyTwilio(msg);
    }

    final smokeNow = status['smoke'] == true;
    if (smokeNow && !_smokeAlertActive) {
      _smokeAlertActive = true;
      setState(() => _smokeDetected = true);
      _addSmokeAlert();
    } else if (!smokeNow && _smokeAlertActive) {
      _smokeAlertActive = false;
      setState(() => _smokeDetected = false);
      _addSmokeClearedMessage();
    }

    final rainNow = status['rain'] == true;
    if (rainNow && !_rainSensorAlertActive) {
      _rainSensorAlertActive = true;
      setState(() => _rainSensorDetected = true);
      _addRainSensorAlert();
    } else if (!rainNow && _rainSensorAlertActive) {
      _rainSensorAlertActive = false;
      setState(() => _rainSensorDetected = false);
      _addRainSensorClearedMessage();
    }
  }

  void _addSmokeAlert() {
    setState(() {
      _chatMessages.add(_ChatMessage.bot(
        '🔥🚨 Smoke detected by your ESP32 sensor! Please check the area immediately.',
        [
          _ChatQuickAction('Turn on fan (ventilate)', _turnFanOnFromChat),
          _ChatQuickAction('I\'m checking now', _acknowledgeSmoke),
        ],
      ));
    });
    _scrollChatToBottom();
    _notifyTwilio('🔥🚨 Weather Alert: Smoke detected by your ESP32 sensor! Please check the area immediately.');
  }

  void _acknowledgeSmoke() {
    setState(() => _chatMessages.add(_ChatMessage.user('I\'m checking now')));
    _scrollChatToBottom();
  }

  void _addSmokeClearedMessage() {
    setState(() => _chatMessages.add(_ChatMessage.bot('✅ Smoke sensor reading is back to normal.')));
    _scrollChatToBottom();
  }

  void _addRainSensorAlert() {
    setState(() {
      _chatMessages.add(_ChatMessage.bot(
        _extended
            ? '🌧️ Rain detected by the ESP32 sensor! The rack should be auto-retracting now. Want me to turn on the fan to help air out the damp clothes, or leave it off?'
            : '🌧️ Rain detected by the ESP32 sensor! Clothes are already indoors. Want me to turn on the fan to help air them out, or leave it off?',
        [
          _ChatQuickAction('Turn on fan', _turnFanOnFromChat),
          _ChatQuickAction('Leave it off', _keepFanOffFromChat),
        ],
      ));
    });
    _scrollChatToBottom();
    _notifyTwilio('🌧️ Weather Alert: The ESP32 rain sensor tripped — rack is auto-retracting.');
  }

  void _keepFanOffFromChat() {
    setState(() {
      _chatMessages.add(_ChatMessage.user('Leave it off'));
      _chatMessages.add(_ChatMessage.bot('Okay, keeping the fan off for now. Let me know if you change your mind.'));
    });
    _scrollChatToBottom();
  }

  void _addRainSensorClearedMessage() {
    setState(() => _chatMessages.add(_ChatMessage.bot('☀️ Rain sensor reading is back to dry.')));
    _scrollChatToBottom();
  }

  Future<void> _turnFanOnFromChat() async {
    setState(() => _chatMessages.add(_ChatMessage.user('Turn on fan (ventilate)')));
    if (!_fanOn) await _toggleFan();
    setState(() {
      _chatMessages.add(_ChatMessage.bot(
        _fanOn ? '🌀 Fan turned on for ventilation.' : '⚠️ Could not turn on the fan — check the ESP32 connection.',
      ));
    });
    _scrollChatToBottom();
  }

  void _onDeviceSelected(String? v) {
    if (v == null) return;
    // FIX #7: the auto-detect entry isn't a real device — it kicks off
    // discovery and leaves the previous selection in place until we find
    // something, so the dropdown never holds a bogus value.
    if (v == '__auto__') {
      _runDiscovery();
      return;
    }
    if (v == '__custom__') {
      setState(() => _showCustomInput = true);
      return;
    }
    setState(() {
      _selectedDevice   = v;
      _ipCtrl.text      = v;
      _showCustomInput  = false;
      _connected        = false;
      _statusMsg        = 'Tap Connect to link to $v.';
      _statusTone       = _StatusTone.neutral;
    });
  }

  // FIX #7: find the ESP32 without the user knowing its address. Tries the
  // mDNS hostname first, then sweeps the /24 of whichever saved IP we have.
  // Scanning is skipped on web, where the browser blocks the requests.
  Future<void> _runDiscovery() async {
    if (_discovering) return;
    setState(() {
      _discovering = true;
      _connected   = false;
      _statusMsg   = 'Searching for the ESP32 on this network…';
      _statusTone  = _StatusTone.neutral;
    });

    final seed = _savedDevices.firstWhere(
      ESP32Service.looksLikeIp,
      orElse: () => '192.168.1.1',
    );

    final found = await ESP32Service.discover(
      subnetSeed: seed,
      allowScan: !kIsWeb,
      onProgress: (m) { if (mounted) setState(() => _statusMsg = m); },
    );

    if (!mounted) return;
    setState(() {
      _discovering = false;
      if (found != null) {
        if (!_savedDevices.contains(found)) _savedDevices.insert(0, found);
        _selectedDevice = found;
        _ipCtrl.text    = found;
        _statusMsg      = '✦ Found the ESP32 at $found.';
        _statusTone     = _StatusTone.success;
      } else {
        _selectedDevice ??= _savedDevices.first;
        _ipCtrl.text = _selectedDevice!;
        _statusMsg = kIsWeb
            ? '⚠️ Auto-detect can\'t scan from a browser. Run the app on Windows, Android or iOS, or enter the IP manually.'
            : '⚠️ Couldn\'t find it. Make sure the ESP32 is powered on and joined to this same WiFi network, then try again or enter the IP manually.';
        _statusTone = _StatusTone.error;
      }
    });

    if (found != null) await _checkConnection();
  }

  void _addCustomDevice() {
    final ip = _customIpCtrl.text.trim();
    if (ip.isEmpty) return;
    setState(() {
      if (!_savedDevices.contains(ip)) _savedDevices.insert(0, ip);
      _selectedDevice  = ip;
      _ipCtrl.text     = ip;
      _showCustomInput = false;
      _customIpCtrl.clear();
      _connected       = false;
      _statusMsg       = 'Tap Connect to link to $ip.';
      _statusTone      = _StatusTone.neutral;
    });
  }

  void _sendChatMessage() {
    final text = _chatInputCtrl.text.trim();
    if (text.isEmpty) return;
    _chatInputCtrl.clear();
    setState(() => _chatMessages.add(_ChatMessage.user(text)));
    _respondToUserMessage(text);
    _scrollChatToBottom();
  }

  void _respondToUserMessage(String text) {
    final lower = text.toLowerCase();
    final w = widget.weather;
    String reply;
    List<_ChatQuickAction> actions = const [];

    if (lower.contains('bring') || lower.contains('inside') || lower.contains('retract') || lower.contains('garage')) {
      reply = 'Sure — retracting the rack into the garage now.';
      _retract();
    } else if (lower.contains('outside') || lower.contains('extract') || lower.contains('hang') || lower.contains('dry')) {
      reply = 'Extracting the rack so your clothes can keep drying outside.';
      _extract();
    } else if (lower.contains('rain') || lower.contains('weather') || lower.contains('status') || lower.contains('chance')) {
      if (w != null) {
        final pct = (w.rainChance * 100).toInt();
        final safe = w.rainChance < _rainAlertThreshold;
        reply = 'Right now in ${w.cityName} there\'s a $pct% chance of rain (${w.description}). '
            '${safe ? 'Should be safe to keep the clothes outside for now.' : 'I\'d bring them into the garage soon.'}';
        actions = [
          _ChatQuickAction('Keep outside', _handleKeepOutside),
          _ChatQuickAction('Bring inside now', _handleBringInside),
        ];
      } else {
        reply = 'I don\'t have live weather data yet — try again in a moment.';
      }
    } else {
      reply = 'I can help decide about your laundry based on the live rain forecast. Try asking "what\'s the rain chance?" or tap a suggestion above.';
    }

    setState(() => _chatMessages.add(_ChatMessage.bot(reply, actions)));
  }

  Future<void> _checkConnection() async {
    if (_host.isEmpty) return;
    setState(() { _checkingConn = true; _statusMsg = 'Connecting to ESP32 at $_host…'; _statusTone = _StatusTone.neutral; });
    final status = await ESP32Service.fetchStatus(_host);
    if (!mounted) return;
    setState(() {
      _checkingConn = false;
      _connected = status != null;
      _connFailCount = 0;
      if (status != null) {
        _extended       = status['extended'] == true;
        _fanOn          = status['fan'] == true;
        _motorRunning   = status['motorRunning'] == true;
        _motorDirection = (status['motorDirection'] ?? 'stopped').toString();
        _mq135WarmingUp = status['smokeSensorWarmingUp'] == true || status['mq135WarmingUp'] == true;
        if (status['rainValue'] is num) _rainValue = (status['rainValue'] as num).toInt();
        if (status['mq135Value'] is num) _mq135Value = (status['mq135Value'] as num).toInt();
        _statusMsg = '✦ Connected to ESP32 at $_host';
        _statusTone = _StatusTone.success;
      } else {
        _statusMsg = '⚠️ Could not reach ESP32 at $_host — check the IP and that it\'s on the same WiFi network.';
        _statusTone = _StatusTone.error;
      }
    });
  }

  // FIX: _run now sets _statusTone alongside _statusMsg so the bottom
  // status card visibly communicates success (green) vs. a rejection or
  // failure (red/amber) instead of everything looking the same neutral
  // color — this was the biggest reason "nothing seems to happen" even
  // when the firmware WAS returning a clear reason.
  Future<void> _run(
    Future<({bool success, String? message})> Function(String host) action, {
    required String successMsg,
    required String failMsg,
    VoidCallback? onSuccess,
  }) async {
    if (_host.isEmpty) {
      setState(() { _statusMsg = 'Select your ESP32 from the list first.'; _statusTone = _StatusTone.error; });
      return;
    }
    if (_busy) return;
    setState(() { _busy = true; _statusMsg = 'Sending command…'; _statusTone = _StatusTone.neutral; });
    final result = await action(_host);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _connected = result.success || _connected;
      _statusMsg = result.success ? successMsg : (result.message ?? failMsg);
      _statusTone = result.success ? _StatusTone.success : _StatusTone.error;
      if (result.success) onSuccess?.call();
    });
  }

  Future<void> _extract() => _run(
    ESP32Service.extractClothes,
    successMsg: '☀️ Clothes extracted for drying.',
    failMsg: '⚠️ Failed to extract — check the ESP32 connection.',
    onSuccess: () {
      setState(() => _extended = true);
      _notifyTwilio('☀️ Weather Alert: Clothes rack extracted — clothes are now outside to dry.');
    },
  );

  Future<void> _retract() => _run(
    ESP32Service.retractClothes,
    successMsg: '🏠 Clothes retracted indoors.',
    failMsg: '⚠️ Failed to retract — check the ESP32 connection.',
    onSuccess: () {
      setState(() => _extended = false);
      _notifyTwilio('🏠 Weather Alert: Clothes rack retracted — clothes are now indoors.');
    },
  );

  // FIX #2 (Dart side): manual calibration so the app and firmware can be
  // re-synced when they disagree about where the rack physically is.
  Future<void> _calibrate(String position) async {
    if (_host.isEmpty) {
      setState(() { _statusMsg = 'Select your ESP32 from the list first.'; _statusTone = _StatusTone.error; });
      return;
    }
    if (_calibrating || _busy) return;
    setState(() { _calibrating = true; _statusMsg = 'Calibrating position…'; _statusTone = _StatusTone.neutral; });
    final result = await ESP32Service.calibrate(_host, position);
    if (!mounted) return;
    setState(() {
      _calibrating = false;
      if (result.success) {
        _extended = position == 'center';
        _connected = true;
        _statusMsg = result.message ?? 'Position calibrated to $position.';
        _statusTone = _StatusTone.success;
      } else {
        _statusMsg = result.message ?? '⚠️ Calibration failed — check the ESP32 connection.';
        _statusTone = _StatusTone.error;
      }
    });
  }

  // FIX #4: fan toggles now notify via Twilio just like extract/retract,
  // whether triggered from the main "Fan On/Off" panel button or from a chat
  // quick-action (_turnFanOnFromChat calls this same method under the hood).
  Future<void> _toggleFan() {
    if (_fanOn) {
      return _run(
        ESP32Service.fanOff,
        successMsg: '🌀 Fan turned off.',
        failMsg: '⚠️ Failed to turn off the fan.',
        onSuccess: () {
          setState(() => _fanOn = false);
          _notifyTwilio('🌀 Weather Alert: Fan turned OFF.');
        },
      );
    }
    return _run(
      ESP32Service.fanOn,
      successMsg: '🌀 Fan turned on.',
      failMsg: '⚠️ Failed to turn on the fan.',
      onSuccess: () {
        setState(() => _fanOn = true);
        _notifyTwilio('🌀 Weather Alert: Fan turned ON.');
      },
    );
  }

  Color _statusColorFor(_StatusTone tone) {
    switch (tone) {
      case _StatusTone.success: return AppColors.success;
      case _StatusTone.error: return AppColors.danger;
      case _StatusTone.neutral: return AppColors.textSub;
    }
  }

  @override
  Widget build(BuildContext context) {
    final rainWarning = widget.weather != null && widget.weather!.rainChance >= 0.6;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [Color(0xFF080514), Color(0xFF060310), Color(0xFF04020C)]),
      ),
      child: Column(children: [
        // Header
        AnimatedBuilder(animation: _glowAnim, builder: (context, child) => Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
            border: Border(bottom: BorderSide(color: AppColors.accentSoft.withValues(alpha: _glowAnim.value * 0.3))),
            boxShadow: [BoxShadow(color: AppColors.accentSoft.withValues(alpha: _glowAnim.value * 0.1), blurRadius: 24, offset: const Offset(0, 4))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(width: 42, height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [AppColors.accentSoft.withValues(alpha: 0.9), AppColors.accentPink.withValues(alpha: 0.9)]),
                  boxShadow: [BoxShadow(color: AppColors.accentSoft.withValues(alpha: _glowAnim.value * 0.6), blurRadius: 18, spreadRadius: 1)],
                ),
                child: const Icon(Icons.checkroom_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Laundry Control', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w800, fontSize: 15, letterSpacing: 0.3)),
                const SizedBox(height: 2),
                Row(children: [
                  Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle,
                    color: _connected ? AppColors.success : AppColors.danger,
                    boxShadow: [BoxShadow(color: (_connected ? AppColors.success : AppColors.danger).withValues(alpha: 0.7), blurRadius: 8)])),
                  const SizedBox(width: 5),
                  Text(_connected ? 'ESP32 connected' : 'ESP32 not connected',
                    style: TextStyle(color: _connected ? AppColors.success : AppColors.danger, fontSize: 11)),
                ]),
              ])),
              if (_connected) Container(
                margin: const EdgeInsets.only(right: 6),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: (_smokeDetected ? AppColors.danger : AppColors.success).withValues(alpha: 0.1),
                  border: Border.all(color: (_smokeDetected ? AppColors.danger : AppColors.success).withValues(alpha: 0.4)),
                ),
                child: Tooltip(
                  message: _mq135Value != null
                      ? (_mq135WarmingUp ? 'MQ135 raw: $_mq135Value (warming up, detection paused)' : 'MQ135 raw: $_mq135Value')
                      : 'Smoke sensor',
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(
                      _mq135WarmingUp
                          ? Icons.hourglass_top_rounded
                          : (_smokeDetected ? Icons.local_fire_department_rounded : Icons.sensors_rounded),
                      color: _mq135WarmingUp
                          ? AppColors.textMuted
                          : (_smokeDetected ? AppColors.danger : AppColors.success),
                      size: 13,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _mq135WarmingUp ? 'Warming up' : (_smokeDetected ? 'Smoke!' : 'Smoke OK'),
                      style: TextStyle(
                        color: _mq135WarmingUp
                            ? AppColors.textMuted
                            : (_smokeDetected ? AppColors.danger : AppColors.success),
                        fontSize: 10.5, fontWeight: FontWeight.w700,
                      ),
                    ),
                  ]),
                ),
              ),
              if (_connected) Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: (_rainSensorDetected ? AppColors.accentCyan : AppColors.success).withValues(alpha: 0.1),
                  border: Border.all(color: (_rainSensorDetected ? AppColors.accentCyan : AppColors.success).withValues(alpha: 0.4)),
                ),
                child: Tooltip(
                  message: _rainValue != null ? 'Rain sensor raw: $_rainValue' : 'Rain sensor',
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(_rainSensorDetected ? Icons.water_drop_rounded : Icons.sensors_rounded,
                      color: _rainSensorDetected ? AppColors.accentCyan : AppColors.success, size: 13),
                    const SizedBox(width: 4),
                    Text(_rainSensorDetected ? 'Rain!' : 'Rain OK',
                      style: TextStyle(color: _rainSensorDetected ? AppColors.accentCyan : AppColors.success, fontSize: 10.5, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
            ]),
            if (_connected) Padding(
              padding: const EdgeInsets.only(top: 8, left: 54),
              child: Row(children: [
                if (_motorRunning) SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(AppColors.accentCyan))),
                if (_motorRunning) const SizedBox(width: 6),
                Text(
                  _motorRunning ? 'Rack motor: $_motorDirection…' : 'Rack: ${_extended ? 'extended' : 'retracted'}',
                  style: TextStyle(color: _motorRunning ? AppColors.accentCyan : AppColors.textMuted, fontSize: 10.5, fontWeight: _motorRunning ? FontWeight.w700 : FontWeight.normal),
                ),
              ]),
            ),
          ]),
        )),

        Expanded(child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // ── ESP32 address ──
            const Text('ESP32 DEVICE', style: TextStyle(color: AppColors.textMuted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.white.withValues(alpha: 0.04),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedDevice,
                      isExpanded: true,
                      isDense: true,
                      dropdownColor: AppColors.card,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded, color: AppColors.textMuted, size: 18),
                      style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
                      items: [
                        ..._savedDevices.map((ip) => DropdownMenuItem(value: ip, child: Text(ip))),
                        // FIX #7: auto-detect entry — no IP typing required.
                        const DropdownMenuItem(value: '__auto__', child: Text('🔍 Auto-detect on this network')),
                        const DropdownMenuItem(value: '__custom__', child: Text('+ Add new device…')),
                      ],
                      onChanged: _discovering ? null : _onDeviceSelected,
                    ),
                  ),
                ),
                if (_showCustomInput) Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    Expanded(child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: Colors.white.withValues(alpha: 0.04),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: TextField(
                        controller: _customIpCtrl,
                        autofocus: true,
                        style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
                        decoration: const InputDecoration(
                          hintText: 'e.g. 192.168.1.75', hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 13),
                          border: InputBorder.none, isDense: true,
                        ),
                        onSubmitted: (_) => _addCustomDevice(),
                      ),
                    )),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _addCustomDevice,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          gradient: const LinearGradient(colors: [AppColors.accentSoft, AppColors.accent]),
                        ),
                        child: const Text('Add', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ]),
                ),
              ])),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: (_checkingConn || _discovering) ? null : _checkConnection,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: const LinearGradient(colors: [AppColors.accentSoft, AppColors.accent]),
                  ),
                  child: (_checkingConn || _discovering)
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Colors.white)))
                      : const Text('Connect', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ),
            ]),

            // FIX #7: explain what the mDNS name is, so "laundry.local" in
            // the dropdown doesn't look like a typo.
            const SizedBox(height: 6),
            const Text(
              'laundry.local is the ESP32\'s mDNS name — it keeps working after the router hands out a new IP. If it fails, pick Auto-detect to sweep the network.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 10.5, height: 1.4),
            ),

            const SizedBox(height: 22),

            if (rainWarning) Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: FrostCard(glow: true, glowColor: AppColors.accentPink, padding: const EdgeInsets.all(14),
                child: Row(children: [
                  const Icon(Icons.warning_amber_rounded, color: AppColors.accentPink, size: 20),
                  const SizedBox(width: 10),
                  Expanded(child: Text(
                    'High rain chance (${(widget.weather!.rainChance * 100).toInt()}%) — consider retracting the clothes.',
                    style: const TextStyle(color: AppColors.textSub, fontSize: 12, height: 1.4))),
                ]),
              ),
            ),

            // ── Rack control ──
            const Text('RACK CONTROL', style: TextStyle(color: AppColors.textMuted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _actionButton(
                icon: Icons.wb_sunny_outlined,
                label: 'Extract',
                sublabel: 'Hang clothes out',
                active: _extended,
                color: AppColors.accentGold,
                onTap: _busy ? null : _extract,
              )),
              const SizedBox(width: 12),
              Expanded(child: _actionButton(
                icon: Icons.garage_outlined,
                label: 'Retract',
                sublabel: 'Bring clothes in',
                active: !_extended,
                color: AppColors.accentCyan,
                onTap: _busy ? null : _retract,
              )),
            ]),

            // FIX #2 (Dart UI): manual calibration controls. There's no
            // limit switch on the hardware, so if Extract/Retract ever
            // look "stuck" (e.g. "Already at center" when it visibly
            // isn't), use these to directly correct what the firmware
            // believes without moving the motor.
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _calibrateButton(
                label: 'Calibrate: Center',
                onTap: _calibrating ? null : () => _calibrate('center'),
              )),
              const SizedBox(width: 12),
              Expanded(child: _calibrateButton(
                label: 'Calibrate: Retracted',
                onTap: _calibrating ? null : () => _calibrate('retracted'),
              )),
            ]),
            const SizedBox(height: 4),
            const Text(
              'No limit switch — use Calibrate to tell the ESP32 where the rack actually is if it ever disagrees.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 10.5, height: 1.4),
            ),

            const SizedBox(height: 22),

            // ── Fan control ──
            const Text('VENTILATION', style: TextStyle(color: AppColors.textMuted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
            const SizedBox(height: 10),
            _actionButton(
              icon: Icons.air_rounded,
              label: _fanOn ? 'Fan On' : 'Fan Off',
              sublabel: _fanOn ? 'Tap to turn off' : 'Tap to turn on',
              active: _fanOn,
              color: AppColors.success,
              fullWidth: true,
              onTap: _busy ? null : _toggleFan,
            ),

            const SizedBox(height: 22),

            // ── Weather assistant chat ──
            const Text('WEATHER ASSISTANT', style: TextStyle(color: AppColors.textMuted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
            const SizedBox(height: 10),
            _buildAssistantChat(),

            const SizedBox(height: 22),

            // ── Twilio notifications ──
            const Text('SMS / WHATSAPP ALERTS', style: TextStyle(color: AppColors.textMuted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
            const SizedBox(height: 10),
            _buildTwilioSection(),

            const SizedBox(height: 22),
            FrostCard(padding: const EdgeInsets.all(14), child: Row(children: [
              if (_busy || _calibrating || _discovering) const Padding(padding: EdgeInsets.only(right: 10),
                child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent)))),
              Expanded(child: Text(_statusMsg, style: TextStyle(color: _statusColorFor(_statusTone), fontSize: 12, height: 1.4, fontWeight: _statusTone == _StatusTone.neutral ? FontWeight.normal : FontWeight.w600))),
            ])),
          ]),
        )),
      ]),
    );
  }

  // ── Twilio notifications UI ─────────────────────────────────────────────────
  Widget _buildTwilioSection() {
    return FrostCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 32, height: 32,
            decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.success.withValues(alpha: 0.15)),
            child: const Icon(Icons.sms_outlined, color: AppColors.success, size: 16),
          ),
          const SizedBox(width: 10),
          const Expanded(child: Text('Twilio notifications', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w800, fontSize: 13))),
          Switch(
            value: _twilioEnabled,
            activeColor: AppColors.success,
            onChanged: (v) => setState(() => _twilioEnabled = v),
          ),
        ]),
        const SizedBox(height: 6),
        const Text('Sends on its own whenever the rack extracts or retracts, the fan switches on or off, rain risk spikes, or the rain/smoke sensor trips.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 11.5, height: 1.4)),
        const SizedBox(height: 12),
        _twilioField(_twilioSidCtrl, 'Account SID', 'ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'),
        const SizedBox(height: 8),
        _twilioField(_twilioTokenCtrl, 'Auth Token', 'Your Twilio auth token', obscure: true),
        const SizedBox(height: 8),
        _twilioField(_twilioFromCtrl, 'Twilio From Number', '+14155238886', phone: true),
        const SizedBox(height: 8),
        _twilioField(_twilioToCtrl, 'Your Number', 'Your own phone, e.g. +639171234567', phone: true),
        const SizedBox(height: 10),
        Row(children: [
          const Text('Channel:', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
          const SizedBox(width: 10),
          _channelChip('SMS', !_twilioUseWhatsapp, () => setState(() => _twilioUseWhatsapp = false)),
          const SizedBox(width: 8),
          _channelChip('WhatsApp', _twilioUseWhatsapp, () => setState(() => _twilioUseWhatsapp = true)),
        ]),
        const SizedBox(height: 12),

        // FIX #5: live pre-flight warning. The From == To mistake is now
        // visible before you ever tap Send, instead of surfacing as a
        // generic "check your credentials" after a wasted API call.
        if (_twilioConfig.validationError != null) Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: AppColors.warning.withValues(alpha: 0.08),
              border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.error_outline_rounded, color: AppColors.warning, size: 15),
              const SizedBox(width: 8),
              Expanded(child: Text(
                _twilioConfig.validationError!,
                style: const TextStyle(color: AppColors.warning, fontSize: 11, height: 1.4),
              )),
            ]),
          ),
        ),

        // FIX #6: the manual "Send test message" button is gone. This strip
        // replaces it — it tells you whether alerts are armed and will fire
        // on their own, without offering anything to press.
        Builder(builder: (_) {
          final invalid = _twilioConfig.validationError;
          final armed   = _twilioEnabled && invalid == null;
          final col     = armed
              ? AppColors.success
              : (_twilioEnabled ? AppColors.warning : AppColors.textMuted);
          final label   = armed
              ? 'Armed — alerts send automatically'
              : (_twilioEnabled ? 'Not armed — fix the issue above' : 'Alerts off — flip the switch to arm');
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: col.withValues(alpha: 0.08),
              border: Border.all(color: col.withValues(alpha: 0.35)),
            ),
            child: Row(children: [
              if (armed) PulseDot(color: col, size: 5)
              else Icon(_twilioEnabled ? Icons.error_outline_rounded : Icons.notifications_off_outlined, color: col, size: 15),
              const SizedBox(width: 8),
              Expanded(child: Text(label,
                style: TextStyle(color: col, fontSize: 11.5, fontWeight: FontWeight.w700))),
            ]),
          );
        }),
        const SizedBox(height: 10),

        // FIX #6: since nothing is manually triggered any more, this log is
        // the proof that it's working — every automatic send lands here with
        // a tick or a cross.
        const Text('AUTOMATIC ALERTS SENT',
          style: TextStyle(color: AppColors.textMuted, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.1)),
        const SizedBox(height: 6),
        if (_twilioLog.isEmpty)
          const Text('Nothing yet. The next rack move, fan toggle, or sensor trip will appear here.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 11, height: 1.4))
        else
          ..._twilioLog.map((e) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(e.ok ? Icons.check_circle_outline_rounded : Icons.cancel_outlined,
                color: e.ok ? AppColors.success : AppColors.danger, size: 13),
              const SizedBox(width: 6),
              Expanded(child: Text(e.text,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textSub, fontSize: 11, height: 1.35))),
              const SizedBox(width: 6),
              Text(_formatTime(e.at), style: const TextStyle(color: AppColors.textMuted, fontSize: 10)),
            ]),
          )),
        const SizedBox(height: 8),
        Text(_twilioStatusMsg, style: TextStyle(
          color: _statusColorFor(_twilioTone),
          fontSize: 11, height: 1.4,
          fontWeight: _twilioTone == _StatusTone.neutral ? FontWeight.normal : FontWeight.w600,
        )),
        if (_lastTwilioSentAt != null) Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('Last sent: ${_formatTime(_lastTwilioSentAt!)}',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 10.5)),
        ),

        // FIX #5: WhatsApp needs a one-time opt-in that SMS doesn't. Without
        // it Twilio returns 63016 / 63015 and nothing arrives, so spell the
        // requirement out whenever the WhatsApp channel is selected.
        if (_twilioUseWhatsapp) Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'WhatsApp sandbox: send "join <your-code>" to '
            '${_twilioFromCtrl.text.trim().isEmpty ? "the sandbox number" : _twilioFromCtrl.text.trim()} '
            'from your phone first. Your code is in the Twilio Console under Messaging → Try it out. '
            'The opt-in expires after 72h of inactivity.',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 10.5, height: 1.4),
          ),
        ),
      ]),
    );
  }

  // FIX #5: onChanged rebuilds so the pre-flight warning updates as you
  // type, and `phone: true` brings up the numeric keypad for E.164 entry.
  Widget _twilioField(
    TextEditingController ctrl,
    String label,
    String hint, {
    bool obscure = false,
    bool phone = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: Colors.white.withValues(alpha: 0.04),
        border: Border.all(color: AppColors.border),
      ),
      child: TextField(
        controller: ctrl,
        obscureText: obscure,
        keyboardType: phone ? TextInputType.phone : TextInputType.text,
        onChanged: (_) => setState(() {}),
        style: const TextStyle(color: AppColors.textPrimary, fontSize: 12.5),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: AppColors.textMuted, fontSize: 11),
          hintText: hint,
          hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 11.5),
          border: InputBorder.none,
          isDense: true,
        ),
      ),
    );
  }

  Widget _channelChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: selected ? AppColors.accent.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.03),
          border: Border.all(color: selected ? AppColors.accent.withValues(alpha: 0.5) : AppColors.border),
        ),
        child: Text(label, style: TextStyle(color: selected ? AppColors.accent : AppColors.textMuted, fontSize: 11.5, fontWeight: FontWeight.w600)),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m ${dt.hour >= 12 ? 'PM' : 'AM'}';
  }

  // ── Assistant chat UI ───────────────────────────────────────────────────────
  Widget _buildAssistantChat() {
    return FrostCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 32, height: 32,
            decoration: const BoxDecoration(shape: BoxShape.circle,
              gradient: LinearGradient(colors: [AppColors.accentCyan, AppColors.accentSoft])),
            child: const Icon(Icons.smart_toy_outlined, color: Colors.white, size: 16),
          ),
          const SizedBox(width: 10),
          const Expanded(child: Text('Ask me about the rain', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w800, fontSize: 13))),
          PulseDot(color: AppColors.success, size: 4),
        ]),
        const SizedBox(height: 10),
        Container(
          height: 220,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: Colors.black.withValues(alpha: 0.18)),
          child: ListView.builder(
            controller: _chatScrollCtrl,
            padding: const EdgeInsets.all(10),
            itemCount: _chatMessages.length,
            itemBuilder: (context, i) => _buildChatBubble(_chatMessages[i]),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: Colors.white.withValues(alpha: 0.04),
              border: Border.all(color: AppColors.border),
            ),
            child: TextField(
              controller: _chatInputCtrl,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'Ask "what\'s the rain chance?"',
                hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
                border: InputBorder.none, isDense: true,
              ),
              onSubmitted: (_) => _sendChatMessage(),
            ),
          )),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _sendChatMessage,
            child: Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: const LinearGradient(colors: [AppColors.accentSoft, AppColors.accent]),
              ),
              child: const Icon(Icons.send_rounded, color: Colors.white, size: 15),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _buildChatBubble(_ChatMessage m) {
    final isBot = m.isBot;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: isBot ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        children: [
          Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: isBot ? MainAxisAlignment.start : MainAxisAlignment.end, children: [
            Flexible(child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: isBot
                    ? LinearGradient(colors: [AppColors.accentSoft.withValues(alpha: 0.22), AppColors.accent.withValues(alpha: 0.1)])
                    : LinearGradient(colors: [AppColors.accentPink.withValues(alpha: 0.25), AppColors.accentPink.withValues(alpha: 0.12)]),
                border: Border.all(color: isBot ? AppColors.accent.withValues(alpha: 0.3) : AppColors.accentPink.withValues(alpha: 0.35)),
              ),
              child: Text(m.text, style: const TextStyle(color: AppColors.textPrimary, fontSize: 12.5, height: 1.4)),
            )),
          ]),
          if (m.actions.isNotEmpty) Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 8, runSpacing: 6, children: m.actions.map((a) => GestureDetector(
              onTap: a.onTap,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
                  color: AppColors.accent.withValues(alpha: 0.1),
                ),
                child: Text(a.label, style: const TextStyle(color: AppColors.accent, fontSize: 11.5, fontWeight: FontWeight.w600)),
              ),
            )).toList()),
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required String sublabel,
    required bool active,
    required Color color,
    bool fullWidth = false,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: fullWidth ? double.infinity : null,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: active ? LinearGradient(colors: [color.withValues(alpha: 0.25), color.withValues(alpha: 0.1)]) : null,
          color: active ? null : Colors.white.withValues(alpha: 0.03),
          border: Border.all(color: active ? color.withValues(alpha: 0.55) : AppColors.border),
          boxShadow: active ? [BoxShadow(color: color.withValues(alpha: 0.25), blurRadius: 18)] : [],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: active ? color : AppColors.textMuted, size: 26),
          const SizedBox(height: 8),
          Text(label, style: TextStyle(color: active ? color : AppColors.textPrimary, fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(height: 2),
          Text(sublabel, style: const TextStyle(color: AppColors.textMuted, fontSize: 10.5), textAlign: TextAlign.center),
        ]),
      ),
    );
  }

  // FIX #2 (Dart UI): small secondary-style button for the calibration
  // actions, visually distinct from the primary rack-control buttons so
  // it's clear this doesn't move the motor.
  Widget _calibrateButton({required String label, VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Colors.white.withValues(alpha: 0.03),
          border: Border.all(color: AppColors.border, style: BorderStyle.solid),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.tune_rounded, color: AppColors.textMuted, size: 14),
          const SizedBox(width: 6),
          Flexible(child: Text(label, textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSub, fontSize: 11.5, fontWeight: FontWeight.w600))),
        ]),
      ),
    );
  }
}

// FIX: simple tri-state enum used to color the bottom status card.
enum _StatusTone { neutral, success, error }

// ─── CHAT MODELS (Weather Assistant) ──────────────────────────────────────────
class _ChatQuickAction {
  final String label;
  final VoidCallback onTap;
  _ChatQuickAction(this.label, this.onTap);
}

class _ChatMessage {
  final String text;
  final bool isBot;
  final List<_ChatQuickAction> actions;
  _ChatMessage.bot(this.text, [this.actions = const []]) : isBot = true;
  _ChatMessage.user(this.text) : isBot = false, actions = const [];
}

// ─── FULL LAUNDRY SCREEN (wide-layout main view when the nav tab is selected) ─
class LaundryScreen extends StatelessWidget {
  final WeatherData? weather;
  const LaundryScreen({super.key, this.weather});
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.checkroom_rounded, size: 64, color: AppColors.accentSoft),
        const SizedBox(height: 16),
        const Text('Laundry Control', style: TextStyle(color: AppColors.textPrimary, fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
        const SizedBox(height: 8),
        const Text('Use the panel on the right →', style: TextStyle(color: AppColors.textMuted, fontSize: 14)),
      ]))),
      const VerticalDivider(width: 1, color: AppColors.border),
      SizedBox(width: 340, child: LaundryControlPanel(weather: weather)),
    ]);
  }
}