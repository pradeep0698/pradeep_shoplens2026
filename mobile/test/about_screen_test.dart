import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shoplens/presentation/screens/about_screen.dart';

void main() {
  testWidgets('AboutScreen shows the hardcoded app version', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AboutScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Version 1.26.0'), findsOneWidget);
  });
}
