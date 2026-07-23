import 'package:flutter_test/flutter_test.dart';

import 'package:sensecraft_voice_app/main.dart';

void main() {
  testWidgets('Demo app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const SenseCraftVoiceDemoApp());
    expect(find.text('SenseCraft Voice SDK Demo'), findsOneWidget);
  });
}
