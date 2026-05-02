import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const RainApp());
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

  // Reverse-geocode a lat/lon into a readable "City, CC" string using
  // BigDataCloud's free client endpoint (no API key required).
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
    // Open-Meteo: free, no key, real-time WMO-standard data
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
        if (idx >= times.length) return HourlyItem(time: '--', icon: '❓', temp: 0);
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

    // Subtle drifting nebula blobs
    final blobs = [
      _Blob(w * 0.15, h * 0.25, w * 0.55, AppColors.nebula1.withOpacity(0.18), t * 0.4),
      _Blob(w * 0.75, h * 0.15, w * 0.45, AppColors.nebula2.withOpacity(0.12), t * 0.3 + 1.2),
      _Blob(w * 0.50, h * 0.75, w * 0.50, AppColors.accentSoft.withOpacity(0.10), t * 0.25 + 2.4),
      _Blob(w * 0.85, h * 0.65, w * 0.35, AppColors.nebula1.withOpacity(0.08), t * 0.35 + 0.8),
    ];

    for (final b in blobs) {
      final dx = math.sin(b.phase) * w * 0.04;
      final dy = math.cos(b.phase * 0.7) * h * 0.03;
      final paint = Paint()
        ..shader = RadialGradient(colors: [b.color, Colors.transparent])
            .createShader(Rect.fromCircle(center: Offset(b.cx + dx, b.cy + dy), radius: b.r));
      canvas.drawCircle(Offset(b.cx + dx, b.cy + dy), b.r, paint);
    }

    // Star field
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
        Paint()..color = Colors.white.withOpacity(opacity),
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
      builder: (_, __) => Container(
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
      builder: (_, __) => SizedBox(
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
              boxShadow: [BoxShadow(color: widget.color.withOpacity(0.6), blurRadius: 8)])),
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
      builder: (_, __) => Text(_displayed, style: widget.style.copyWith(color: _color.value)));
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
          colors: [AppColors.card.withOpacity(0.85), AppColors.cardGlow.withOpacity(0.6)],
        ),
        border: Border.all(color: glow ? AppColors.borderBright : AppColors.border),
        boxShadow: glow ? [BoxShadow(color: gc.withOpacity(0.18), blurRadius: 28, spreadRadius: 0)] : [BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 14)],
      ),
      child: child,
    );
  }
}

// ─── APP ROOT ─────────────────────────────────────────────────────────────────
class RainApp extends StatelessWidget {
  const RainApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Cosmos Weather',
      theme: ThemeData(
        scaffoldBackgroundColor: AppColors.bg,
        colorScheme: const ColorScheme.dark(primary: AppColors.accent, surface: AppColors.panel),
        textTheme: const TextTheme(bodyMedium: TextStyle(color: AppColors.textPrimary, fontFamily: 'monospace')),
      ),
      home: const HomeScreen(),
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

  Future<void> _silentRefresh() async {
    if (_cachedLat == null || _silentFetching) return;
    setState(() => _silentFetching = true);
    try {
      final data = await WeatherService.fetchWeather(_cachedLat!, _cachedLon!, _cachedCityName!);
      if (data != null && mounted) setState(() { _weather = data; _error = ''; });
    } catch (_) {} finally {
      if (mounted) setState(() => _silentFetching = false);
    }
  }

  // Ask the OS for GPS, then fetch weather + reverse-geocode for display.
  // Falls back to Manila if permission is denied, services are off, or GPS times out.
  Future<void> _loadWeatherByGPS() async {
    setState(() { _loading = true; _error = ''; });
    _fadeCtrl.reset();

    try {
      // 1. Service enabled?
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) throw Exception('Location services are disabled');

      // 2. Permission
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        throw Exception('Location permission denied');
      }

      // 3. Current position (medium accuracy is plenty for weather)
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 12),
        ),
      );

      // 4. Reverse-geocode for a friendly label; fall back to coords
      final label = await WeatherService.reverseGeocode(pos.latitude, pos.longitude)
          ?? '${pos.latitude.toStringAsFixed(2)}, ${pos.longitude.toStringAsFixed(2)}';

      _cachedLat      = pos.latitude;
      _cachedLon      = pos.longitude;
      _cachedCityName = label;
      _currentCity    = label;

      final data = await WeatherService.fetchWeather(_cachedLat!, _cachedLon!, _cachedCityName!);
      if (data == null) throw Exception('Could not load weather data');
      if (!mounted) return;
      setState(() { _weather = data; _loading = false; _silentFetching = false; });
      _fadeCtrl.forward();
      _startCountdown();
    } catch (e) {
      // GPS failed — fall back to Manila so the app still loads.
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

      final data = await WeatherService.fetchWeather(_cachedLat!, _cachedLon!, _cachedCityName!);
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
      (Icons.auto_awesome_rounded, 'Cosmos'),
      (Icons.calendar_view_week_rounded, 'Forecast'),
      (Icons.explore_rounded, 'Map'),
      (Icons.notifications_outlined, 'Alerts'),
      (Icons.smart_toy_outlined, 'AI Chat'),
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
        // Logo
        Container(width: 44, height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: const LinearGradient(colors: [AppColors.accentSoft, AppColors.accentPink],
              begin: Alignment.topLeft, end: Alignment.bottomRight),
            boxShadow: [BoxShadow(color: AppColors.accentSoft.withOpacity(0.5), blurRadius: 16)],
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
                gradient: selected ? LinearGradient(colors: [AppColors.accentSoft.withOpacity(0.25), AppColors.accent.withOpacity(0.15)]) : null,
                border: selected ? Border.all(color: AppColors.accent.withOpacity(0.45)) : null,
                boxShadow: selected ? [BoxShadow(color: AppColors.accent.withOpacity(0.2), blurRadius: 16)] : [],
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
            border: Border.all(color: AppColors.accent.withOpacity(0.4), width: 1.5),
            color: AppColors.accent.withOpacity(0.1)),
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
        gradient: LinearGradient(colors: [AppColors.panel, AppColors.bg.withOpacity(0.8)]),
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(children: [
        ShaderMask(
          shaderCallback: (b) => const LinearGradient(colors: [AppColors.accent, AppColors.accentPink]).createShader(b),
          child: const Text('Cosmos Weather', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17, letterSpacing: 0.5)),
        ),
        const SizedBox(width: 24),
        Expanded(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Container(height: 38,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: AppColors.card.withOpacity(0.8),
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
                      color: AppColors.accent.withOpacity(0.12),
                      border: Border.all(color: AppColors.accent.withOpacity(0.35)),
                    ),
                    child: const Icon(Icons.my_location_rounded, color: AppColors.accent, size: 14),
                  ),
                ),
              ),
            ]),
          ),
        )),
        const Spacer(),
        // Live indicator
        AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _silentFetching ? AppColors.accentPink.withOpacity(0.4) : AppColors.success.withOpacity(0.35)),
            color: _silentFetching ? AppColors.accentPink.withOpacity(0.08) : AppColors.success.withOpacity(0.08),
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
            border: Border.all(color: AppColors.accent.withOpacity(0.3)),
            color: AppColors.accent.withOpacity(0.08),
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

      // Top row — emoji + big temp. Countdown ring only shown here on wide
      // screens; on narrow, the top-bar ring is enough.
      final topRow = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: emojiBox, height: emojiBox,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [AppColors.accentSoft.withOpacity(0.3), Colors.transparent]),
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

      // Text block — always full width below the top row on narrow, or inside
      // the row on wide.
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
            BoxShadow(color: AppColors.accentSoft.withOpacity(0.25), blurRadius: 40, spreadRadius: -5),
            BoxShadow(color: AppColors.accentPink.withOpacity(0.1), blurRadius: 60, offset: const Offset(0, 20)),
          ],
        ),
        child: isNarrow
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                topRow,
                const SizedBox(height: 16),
                textBlock,
              ])
            : Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                // Wide layout: keep old side-by-side
                Container(
                  width: emojiBox, height: emojiBox,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [AppColors.accentSoft.withOpacity(0.3), Colors.transparent]),
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
        color: AppColors.accent.withOpacity(0.08),
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
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: c.accent.withOpacity(0.15)),
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
      // 2×2 grid on phones
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

    // Single row on desktop
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
              gradient: h.isNow ? LinearGradient(colors: [AppColors.accentSoft.withOpacity(0.25), AppColors.accent.withOpacity(0.12)]) : null,
              color: h.isNow ? null : AppColors.bg.withOpacity(0.5),
              border: Border.all(color: h.isNow ? AppColors.accent.withOpacity(0.55) : AppColors.border),
              boxShadow: h.isNow ? [BoxShadow(color: AppColors.accent.withOpacity(0.2), blurRadius: 20)] : [],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(h.time, style: TextStyle(color: h.isNow ? AppColors.accent : AppColors.textMuted, fontSize: 11, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(h.icon, style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 6),
              AnimatedStatValue(value: '${h.temp}°', style: TextStyle(
                color: h.isNow ? AppColors.accent : AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              // Rain chance mini bar — wrapped in SizedBox to give it a bounded width
              // inside the horizontal SingleChildScrollView.
              SizedBox(
                width: 42,
                height: 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: h.rain,
                    minHeight: 3,
                    backgroundColor: AppColors.border,
                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.accentCyan.withOpacity(0.7)),
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
      ...daily.asMap().entries.map((e) {
        final d = e.value;
        final isLast = e.key == daily.length - 1;
        final isToday = e.key == 0;
        return Column(children: [
          Container(
            padding: isToday ? const EdgeInsets.symmetric(vertical: 6, horizontal: 8) : EdgeInsets.zero,
            decoration: isToday ? BoxDecoration(borderRadius: BorderRadius.circular(10), color: AppColors.accent.withOpacity(0.07)) : null,
            child: Row(children: [
              SizedBox(width: 48, child: Text(d.day, style: TextStyle(color: isToday ? AppColors.accent : AppColors.textSub, fontSize: 13, fontWeight: isToday ? FontWeight.w700 : FontWeight.normal))),
              Text(d.icon, style: const TextStyle(fontSize: 17)),
              const SizedBox(width: 10),
              Expanded(child: Text(d.desc, style: const TextStyle(color: AppColors.textMuted, fontSize: 12))),
              SizedBox(width: 90, height: 3, child: ClipRRect(borderRadius: BorderRadius.circular(2), child: LinearProgressIndicator(
                value: d.rainPct, backgroundColor: AppColors.border,
                valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent),
              ))),
              const SizedBox(width: 12),
              Text('${d.min}°', style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
              const SizedBox(width: 8),
              Text('${d.max}°', style: const TextStyle(color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w700)),
            ]),
          ),
          if (!isLast) Divider(color: AppColors.border.withOpacity(0.6), height: 18),
        ]);
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
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: col.withOpacity(0.15),
            border: Border.all(color: col.withOpacity(0.3))),
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
    if (w.rainChance >= 0.7) parts.add('⚠️ High rain (${(w.rainChance * 100).toInt()}%) — bring an umbrella.');
    else if (w.rainChance >= 0.4) parts.add('🌂 Moderate rain (${(w.rainChance * 100).toInt()}%) — umbrella recommended.');
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
            boxShadow: [BoxShadow(color: AppColors.accentSoft.withOpacity(0.4), blurRadius: 20)],
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

      // Hourly + weekly: side-by-side on wide, stacked on narrow.
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

      return FadeTransition(
        opacity: _fadeAnim,
        child: SingleChildScrollView(
          padding: EdgeInsets.all(pad),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              PulseDot(color: _silentFetching ? AppColors.accentPink : AppColors.success, size: 5),
              const SizedBox(width: 8),
              Flexible(child: Text(
                _silentFetching ? 'Syncing with satellite…' : 'Live data · Open-Meteo',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
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
                Expanded(child: _selectedNav == 4 ? const ChatScreen() : _buildDashboard()),
                if (_selectedNav != 4) ...[
                  Container(width: 1, color: AppColors.border),
                  SizedBox(width: 340, child: ChatPanel(weather: _weather)),
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
            child: const Text('Cosmos Weather', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
          ),
          actions: [
            if (_weather != null) Padding(padding: const EdgeInsets.only(right: 4),
              child: Center(child: PulseDot(color: _silentFetching ? AppColors.accentPink : AppColors.success, size: 5))),
            Padding(padding: const EdgeInsets.only(right: 10),
              child: CountdownRing(secondsRemaining: _secondsToRefresh, totalSeconds: _refreshIntervalSeconds)),
          ],
        ),
        body: NebulaBackground(child: Column(children: [
          if (!isMedium) Container(color: AppColors.panel.withOpacity(0.9),
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: _buildCompactSearch()),
          Container(height: 1, color: AppColors.border),
          Expanded(child: _selectedNav == 4 ? ChatPanel(weather: _weather) : _buildDashboard()),
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
              color: AppColors.accent.withOpacity(0.12),
              border: Border.all(color: AppColors.accent.withOpacity(0.35)),
            ),
            child: const Icon(Icons.my_location_rounded, color: AppColors.accent, size: 13),
          ),
        ),
      ]),
    );
  }

  Widget _buildBottomNav() {
    final items = [(Icons.auto_awesome_rounded, 'Cosmos'), (Icons.calendar_view_week_rounded, 'Forecast'), (Icons.explore_rounded, 'Map'), (Icons.notifications_outlined, 'Alerts'), (Icons.smart_toy_outlined, 'AI')];
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

// ─── CHAT MESSAGE ─────────────────────────────────────────────────────────────
class _ChatMsg {
  final bool isUser;
  final String text, time;
  _ChatMsg(this.isUser, this.text, this.time);
}

// ─── ANIMATED CHAT BUBBLE ─────────────────────────────────────────────────────
class _Bubble extends StatefulWidget {
  final _ChatMsg msg;
  const _Bubble({super.key, required this.msg});
  @override State<_Bubble> createState() => _BubbleState();
}
class _BubbleState extends State<_Bubble> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _slide, _fade, _scale;

  @override
  void initState() {
    super.initState();
    _ctrl  = AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
    _slide = Tween<double>(begin: widget.msg.isUser ? 50.0 : -50.0, end: 0.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _fade  = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.85, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));
    _ctrl.forward();
  }

  @override void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final isUser = widget.msg.isUser;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) => Transform.translate(
        offset: Offset(_slide.value, 0),
        child: Opacity(opacity: _fade.value, child: Transform.scale(
          scale: _scale.value,
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: child,
        )),
      ),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
            Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
              if (!isUser) ...[
                Container(
                  width: 32, height: 32,
                  margin: const EdgeInsets.only(right: 8, bottom: 2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(colors: [AppColors.accentSoft, AppColors.accentPink]),
                    boxShadow: [BoxShadow(color: AppColors.accentSoft.withOpacity(0.5), blurRadius: 12)],
                  ),
                  child: const Center(child: Text('✦', style: TextStyle(fontSize: 14, color: Colors.white))),
                ),
              ],
              Container(
                constraints: const BoxConstraints(maxWidth: 270),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(20), topRight: const Radius.circular(20),
                    bottomLeft: Radius.circular(isUser ? 20 : 4),
                    bottomRight: Radius.circular(isUser ? 4 : 20),
                  ),
                  gradient: isUser
                      ? LinearGradient(colors: [AppColors.accentSoft.withOpacity(0.3), AppColors.accent.withOpacity(0.15)], begin: Alignment.topLeft, end: Alignment.bottomRight)
                      : null,
                  color: isUser ? null : Colors.white.withOpacity(0.05),
                  border: Border.all(color: isUser ? AppColors.accent.withOpacity(0.4) : Colors.white.withOpacity(0.09)),
                  boxShadow: [BoxShadow(color: isUser ? AppColors.accentSoft.withOpacity(0.15) : Colors.black.withOpacity(0.2), blurRadius: 20, offset: const Offset(0, 4))],
                ),
                child: Text(widget.msg.text, style: TextStyle(
                  color: isUser ? AppColors.accentCyan.withOpacity(0.95) : AppColors.textPrimary,
                  fontSize: 13.5, height: 1.55,
                )),
              ),
              if (isUser) ...[
                Container(
                  width: 32, height: 32, margin: const EdgeInsets.only(left: 8, bottom: 2),
                  decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.accent.withOpacity(0.12),
                    border: Border.all(color: AppColors.accent.withOpacity(0.4), width: 1.5)),
                  child: const Icon(Icons.person_outline_rounded, color: AppColors.accent, size: 16),
                ),
              ],
            ]),
            Padding(
              padding: EdgeInsets.only(top: 4, left: isUser ? 0 : 40, right: isUser ? 40 : 0),
              child: Text(widget.msg.time, style: TextStyle(color: AppColors.textMuted.withOpacity(0.6), fontSize: 10)),
            ),
          ]),
        ),
      ),
    );
  }
}

// ─── WAVE TYPING INDICATOR ────────────────────────────────────────────────────
class _WaveTyping extends StatefulWidget {
  const _WaveTyping();
  @override State<_WaveTyping> createState() => _WaveTypingState();
}
class _WaveTypingState extends State<_WaveTyping> with TickerProviderStateMixin {
  late List<AnimationController> _dots;
  @override
  void initState() {
    super.initState();
    _dots = List.generate(3, (i) {
      final c = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
      Future.delayed(Duration(milliseconds: i * 150), () { if (mounted) c.repeat(reverse: true); });
      return c;
    });
  }
  @override void dispose() { for (final d in _dots) d.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
      Container(width: 32, height: 32, margin: const EdgeInsets.only(right: 8, bottom: 2),
        decoration: BoxDecoration(shape: BoxShape.circle,
          gradient: const LinearGradient(colors: [AppColors.accentSoft, AppColors.accentPink]),
          boxShadow: [BoxShadow(color: AppColors.accentSoft.withOpacity(0.5), blurRadius: 12)]),
        child: const Center(child: Text('✦', style: TextStyle(fontSize: 14, color: Colors.white))),
      ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20), bottomRight: Radius.circular(20), bottomLeft: Radius.circular(4)),
          border: Border.all(color: Colors.white.withOpacity(0.09)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: List.generate(3, (i) {
          return AnimatedBuilder(animation: _dots[i], builder: (_, __) {
            return Transform.translate(
              offset: Offset(0, -4 * _dots[i].value),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 3), width: 7, height: 7,
                decoration: BoxDecoration(shape: BoxShape.circle,
                  color: AppColors.accent.withOpacity(0.4 + _dots[i].value * 0.6),
                  boxShadow: [BoxShadow(color: AppColors.accent.withOpacity(_dots[i].value * 0.5), blurRadius: 8)]),
              ),
            );
          });
        })),
      ),
    ]);
  }
}

// ─── CHAT PANEL (Anthropic Claude API) ───────────────────────────────────────
class ChatPanel extends StatefulWidget {
  final WeatherData? weather;
  const ChatPanel({super.key, this.weather});
  @override State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> with TickerProviderStateMixin {
  final TextEditingController _ctrl   = TextEditingController();
  final ScrollController       _scroll = ScrollController();
  final FocusNode              _focus  = FocusNode();
  bool _aiLoading    = false;
  bool _inputFocused = false;
  late AnimationController _glowCtrl;
  late Animation<double>   _glowAnim;

  final List<Map<String, dynamic>> _history = [];
  final List<_ChatMsg> messages = [
    _ChatMsg(false, '✦ Hello! I\'m Cosmos AI, powered by Llama 3.3 on Groq. Ask me anything about today\'s weather — rain chance, UV, travel advice, or what to wear!', _nowTime()),
  ];

  static String _nowTime() {
    final now = DateTime.now();
    final h = now.hour % 12 == 0 ? 12 : now.hour % 12;
    return '$h:${now.minute.toString().padLeft(2, '0')} ${now.hour >= 12 ? 'PM' : 'AM'}';
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() => _inputFocused = _focus.hasFocus));
    _glowCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800))..repeat(reverse: true);
    _glowAnim = Tween<double>(begin: 0.2, end: 0.7).animate(CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _ctrl.dispose(); _scroll.dispose(); _focus.dispose(); _glowCtrl.dispose(); super.dispose(); }

  String _buildSystemPrompt() {
    final w = widget.weather;
    if (w == null) return 'You are Cosmos AI, a helpful weather assistant embedded in a beautiful space-themed dashboard. Answer weather questions helpfully and concisely. Use emojis where appropriate.';
    return '''You are Cosmos AI, a smart weather assistant embedded in a cosmic-themed dashboard.

Live weather data for ${w.cityName}:
• Temperature: ${w.temperature.toInt()}°C (feels like ${w.feelsLike.toInt()}°C)
• Humidity: ${w.humidity.toInt()}%
• Wind: ${w.windSpeed.toInt()} km/h
• Rain probability: ${(w.rainChance * 100).toInt()}%
• Conditions: ${w.description}
• UV Index: ${w.uvIndex}
• Visibility: ${w.visibility.toStringAsFixed(0)} km
• Cloud cover: ${w.cloudCover}%
• Data fetched: ${w.fetchedAt.toLocal()}

7-day outlook:
${w.daily.take(7).map((d) => '• ${d.day}: ${d.desc}, ${d.min}°–${d.max}°C, ${(d.rainPct * 100).toInt()}% rain').join('\n')}

Data source: Open-Meteo (real-time, WMO-standard).
Answer weather questions with this live data. Be concise and use relevant emojis. If asked about something unrelated to weather, politely redirect.''';
  }

  Future<void> _sendMessage() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _aiLoading) return;
    final time = _nowTime();
    setState(() { messages.add(_ChatMsg(true, text, time)); _aiLoading = true; });
    _ctrl.clear();
    _scrollToBottom();

    try {
      _history.add({'role': 'user', 'content': text});

      // Groq API (OpenAI-compatible) — Llama 3.3 70B Versatile
      final chatMessages = <Map<String, String>>[
        {'role': 'system', 'content': _buildSystemPrompt()},
        ..._history.map((m) => {'role': m['role'] as String, 'content': m['content'] as String}),
      ];

      final response = await http.post(
        Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer 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',
        },
        body: jsonEncode({
          'model': 'llama-3.3-70b-versatile',
          'messages': chatMessages,
          'max_tokens': 1024,
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final reply = (data['choices'][0]['message']['content'] ?? 'No response').toString();
        _history.add({'role': 'assistant', 'content': reply});
        if (mounted) setState(() { messages.add(_ChatMsg(false, reply, _nowTime())); _aiLoading = false; });
      } else {
        String err = response.body;
        try { err = (jsonDecode(response.body) as Map)['error']?['message']?.toString() ?? err; } catch (_) {}
        throw Exception(err);
      }
    } catch (e) {
      if (_history.isNotEmpty && _history.last['role'] == 'user') _history.removeLast();
      if (mounted) setState(() { messages.add(_ChatMsg(false, '⚠️ ${e.toString().replaceAll('Exception: ', '')}', _nowTime())); _aiLoading = false; });
    }
    _scrollToBottom();
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 150), () {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 500), curve: Curves.easeOutCubic);
    });
  }

  final _chips = ['🌊 Typhoon risk?', '☀️ UV today?', '✈️ Best travel day', '🌡️ Heat index', '👗 What to wear?'];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [Color(0xFF080514), Color(0xFF060310), Color(0xFF04020C)]),
      ),
      child: Column(children: [
        // Header
        AnimatedBuilder(animation: _glowAnim, builder: (_, __) => Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            border: Border(bottom: BorderSide(color: AppColors.accentSoft.withOpacity(_glowAnim.value * 0.3))),
            boxShadow: [BoxShadow(color: AppColors.accentSoft.withOpacity(_glowAnim.value * 0.1), blurRadius: 24, offset: const Offset(0, 4))],
          ),
          child: Row(children: [
            Container(width: 42, height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [AppColors.accentSoft.withOpacity(0.9), AppColors.accentPink.withOpacity(0.9)]),
                boxShadow: [BoxShadow(color: AppColors.accentSoft.withOpacity(_glowAnim.value * 0.6), blurRadius: 18, spreadRadius: 1)],
              ),
              child: const Center(child: Text('✦', style: TextStyle(fontSize: 20, color: Colors.white))),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Cosmos AI', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w800, fontSize: 15, letterSpacing: 0.3)),
              const SizedBox(height: 2),
              Row(children: [
                Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.success, boxShadow: [BoxShadow(color: AppColors.success.withOpacity(0.7), blurRadius: 8)])),
                const SizedBox(width: 5),
                Text(_aiLoading ? 'Thinking…' : 'Online · Llama 3.3 70B',
                  style: TextStyle(color: _aiLoading ? AppColors.accentCyan : AppColors.success, fontSize: 11)),
              ]),
            ])),
            if (_history.isNotEmpty) GestureDetector(
              onTap: () => setState(() { _history.clear(); messages.removeRange(1, messages.length); }),
              child: Container(width: 34, height: 34,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: Colors.white.withOpacity(0.05), border: Border.all(color: Colors.white.withOpacity(0.1))),
                child: const Icon(Icons.delete_sweep_rounded, color: AppColors.textMuted, size: 16)),
            ),
          ]),
        )),

        // Messages
        Expanded(child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
          itemCount: messages.length + (_aiLoading ? 1 : 0),
          itemBuilder: (ctx, i) {
            if (_aiLoading && i == messages.length) return const Padding(padding: EdgeInsets.only(bottom: 14), child: Align(alignment: Alignment.centerLeft, child: _WaveTyping()));
            return _Bubble(key: ValueKey(i), msg: messages[i]);
          },
        )),

        // Quick chips
        if (!_inputFocused) Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
          child: SingleChildScrollView(scrollDirection: Axis.horizontal,
            child: Row(children: _chips.map((c) => GestureDetector(
              onTap: () { _ctrl.text = c.replaceAll(RegExp(r'[^\x00-\x7F]'), '').trim(); },
              child: Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: AppColors.accentSoft.withOpacity(0.08),
                  border: Border.all(color: AppColors.accentSoft.withOpacity(0.25)),
                ),
                child: Text(c, style: const TextStyle(color: AppColors.accent, fontSize: 11.5)),
              ),
            )).toList()),
          ),
        ),

        // Input
        Container(
          padding: EdgeInsets.fromLTRB(14, 10, 14, MediaQuery.of(context).padding.bottom + 14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            border: Border(top: BorderSide(color: _inputFocused ? AppColors.accent.withOpacity(0.35) : Colors.white.withOpacity(0.07))),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                color: _inputFocused ? AppColors.accentSoft.withOpacity(0.07) : Colors.white.withOpacity(0.04),
                border: Border.all(color: _inputFocused ? AppColors.accent.withOpacity(0.5) : Colors.white.withOpacity(0.09)),
                boxShadow: _inputFocused ? [BoxShadow(color: AppColors.accent.withOpacity(0.15), blurRadius: 18)] : [],
              ),
              child: TextField(
                controller: _ctrl, focusNode: _focus,
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 14, height: 1.4),
                maxLines: 4, minLines: 1,
                decoration: InputDecoration(
                  hintText: 'Ask Cosmos AI…',
                  hintStyle: TextStyle(color: AppColors.textMuted.withOpacity(0.55), fontSize: 14),
                  border: InputBorder.none, isDense: true,
                ),
                onSubmitted: (_) => _sendMessage(),
              ),
            )),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: _aiLoading ? null : _sendMessage,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: 46, height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: _aiLoading ? null : const LinearGradient(colors: [AppColors.accentSoft, AppColors.accentPink], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  color: _aiLoading ? Colors.white.withOpacity(0.07) : null,
                  boxShadow: _aiLoading ? [] : [BoxShadow(color: AppColors.accentSoft.withOpacity(0.5), blurRadius: 16, offset: const Offset(0, 2))],
                ),
                child: _aiLoading
                    ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent))))
                    : const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 20),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ─── FULL CHAT SCREEN ─────────────────────────────────────────────────────────
class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return const Row(children: [
      Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('✦', style: TextStyle(fontSize: 64, color: AppColors.accentSoft)),
        SizedBox(height: 16),
        Text('Cosmos AI', style: TextStyle(color: AppColors.textPrimary, fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
        SizedBox(height: 8),
        Text('Use the chat panel on the right →', style: TextStyle(color: AppColors.textMuted, fontSize: 14)),
      ]))),
      VerticalDivider(width: 1, color: AppColors.border),
      SizedBox(width: 340, child: ChatPanel()),
    ]);
  }
}