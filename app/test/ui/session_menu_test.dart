// The transcript menu's widgets: the ⋮ button, and the compact / rename /
// thinking-level dialogs. The observable is what the user sees or taps, plus
// each dialog's return value.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/ui/session_menu.dart';

/// A host whose app bar carries the menu. Callbacks record what fired.
Widget menuHost({
  String? thinkingLevel,
  List<String>? fired,
}) => MaterialApp(
  home: Scaffold(
    appBar: AppBar(
      actions: [
        SessionMenuButton(
          thinkingLevel: thinkingLevel,
          onCompact: () => fired?.add('compact'),
          onRename: () => fired?.add('rename'),
          onThinkingLevel: () => fired?.add('thinking'),
        ),
      ],
    ),
  ),
);

/// A host with a single button that opens [open] and records its result.
Widget triggerHost(Future<void> Function(BuildContext context) open) =>
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('trigger'),
            onPressed: () => open(context),
            child: const Text('open'),
          ),
        ),
      ),
    );

void main() {
  testWidgets('the menu offers compact, rename and thinking level', (
    tester,
  ) async {
    await tester.pumpWidget(menuHost());
    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();

    expect(find.text('Compact'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Thinking level'), findsOneWidget);
  });

  testWidgets('the menu shows the active thinking level', (tester) async {
    await tester.pumpWidget(menuHost(thinkingLevel: 'high'));
    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('session-menu-thinking-level')),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('session-menu-thinking-level'))).data,
      'high',
    );
  });

  testWidgets('the menu hides the level when none is known', (tester) async {
    await tester.pumpWidget(menuHost());
    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('session-menu-thinking-level')), findsNothing);
  });

  testWidgets('the menu routes each action', (tester) async {
    final fired = <String>[];
    await tester.pumpWidget(menuHost(fired: fired));

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compact'));
    await tester.pumpAndSettle();
    expect(fired, ['compact']);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(fired, ['compact', 'rename']);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Thinking level'));
    await tester.pumpAndSettle();
    expect(fired, ['compact', 'rename', 'thinking']);
  });

  testWidgets('compact asks before it acts', (tester) async {
    bool? confirmed;
    await tester.pumpWidget(
      triggerHost((context) async {
        confirmed = await confirmCompact(context);
      }),
    );

    // Negating without confirming must return false.
    await tester.tap(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();
    expect(find.text('Compact session?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('compact-confirm-no')));
    await tester.pumpAndSettle();
    expect(confirmed, isFalse);

    // Confirming returns true.
    await tester.tap(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('compact-confirm-yes')));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });

  testWidgets('the rename dialog returns the typed name', (tester) async {
    String? renamed;
    await tester.pumpWidget(
      triggerHost((context) async {
        renamed = await promptRename(context, 'old name');
      }),
    );

    await tester.tap(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();
    // Prefilled with the current name.
    expect(find.widgetWithText(TextField, 'old name'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('rename-field')), 'new name');
    await tester.pump();
    await tester.tap(find.byKey(const Key('rename-submit')));
    await tester.pumpAndSettle();
    expect(renamed, 'new name');
  });

  testWidgets('the rename dialog refuses an empty name', (tester) async {
    await tester.pumpWidget(
      triggerHost((context) async {
        await promptRename(context, 'old name');
      }),
    );

    await tester.tap(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('rename-field')), '   ');
    await tester.pump();
    expect(
      tester.widget<TextButton>(find.byKey(const Key('rename-submit'))).onPressed,
      isNull,
    );

    await tester.enterText(find.byKey(const Key('rename-field')), '');
    await tester.pump();
    expect(
      tester.widget<TextButton>(find.byKey(const Key('rename-submit'))).onPressed,
      isNull,
    );
  });

  testWidgets('the thinking picker marks the active level and returns the tapped one', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      triggerHost((context) async {
        picked = await pickThinkingLevel(context, 'high');
      }),
    );

    await tester.tap(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('thinking-high')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('thinking-low')));
    await tester.pumpAndSettle();
    expect(picked, 'low');
  });

  testWidgets('the thinking picker does not overflow at a large text scale', (
    tester,
  ) async {
    // A phone-sized viewport: at 2× text scale the seven rows do not fit in the
    // sheet's height, so the list must scroll rather than overflow.
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        // Copy the ambient MediaQuery so view insets survive, and raise only the
        // text scale.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const Key('trigger'),
              onPressed: () async {
                picked = await pickThinkingLevel(context, 'high');
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // The last row is not built until it is scrolled into view. Asserting it is
    // absent now is what proves the list actually scrolls: a version that
    // passed because all seven rows happened to fit would fail here.
    expect(find.byKey(const Key('thinking-max')), findsNothing);

    await tester.scrollUntilVisible(
      find.byKey(const Key('thinking-max')),
      100,
      scrollable: find.descendant(
        of: find.byKey(const Key('thinking-picker')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('thinking-max')));
    await tester.pumpAndSettle();
    expect(picked, 'max');
  });
}
