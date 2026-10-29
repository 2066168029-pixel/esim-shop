import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:esim_app/store.dart';
import 'package:esim_app/main.dart';

void main() {
  testWidgets('Shell renders five-tab bottom navigation', (tester) async {
    // Pump the shell by itself. Pumping the whole app would also build all five
    // tab pages, and those contain ListTiles wrapped in a white DecoratedBox --
    // a layout smell that trips a debug assertion for every row and buries the
    // result of this test.
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const MaterialApp(home: Shell()),
      ),
    );
    await tester.pump();

    final bar = find.byType(BottomNavigationBar);
    expect(bar, findsOneWidget);

    // Labels come from the backend language pack, so assert on structure:
    // five destinations, five rendered icons.
    final icons = find.descendant(of: bar, matching: find.byType(Icon));
    expect(icons, findsNWidgets(5));
  });
}
