import 'package:flutter_test/flutter_test.dart';
import 'package:rain_clothes_app/main.dart';

void main() {
  testWidgets('Weather Alert app starts successfully',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WeatherAlertApp());

    expect(find.byType(WeatherAlertApp), findsOneWidget);
  });
}