// The transcript menu's widgets: the ⋮ button, and the compact / rename /
// thinking-level dialogs. The observable is what the user sees or taps, plus
// each dialog's return value.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/ui/session_menu.dart';

/// A host whose app bar carries the menu. Callbacks record what fired.
Widget menuHost({
  String? thinkingLevel,
  String? model,
  List<String>? fired,
}) => MaterialApp(
  home: Scaffold(
    appBar: AppBar(
      actions: [
        SessionMenuButton(
          thinkingLevel: thinkingLevel,
          model: model,
          onCompact: () => fired?.add('compact'),
          onRename: () => fired?.add('rename'),
          onThinkingLevel: () => fired?.add('thinking'),
          onModel: () => fired?.add('model'),
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

const List<ModelSummary> catalog = [
  ModelSummary(provider: 'anthropic', id: 'claude-sonnet-4', name: 'Claude Sonnet 4'),
  ModelSummary(provider: 'openai', id: 'gpt-5', name: 'GPT-5'),
  ModelSummary(provider: 'openrouter', id: 'deepseek-chat', name: 'DeepSeek Chat'),
  ModelSummary(provider: 'openrouter', id: 'qwen3', name: 'Qwen3'),
];
List<String> catalogIds(List<ModelSummary> models) =>
    [for (final m in models) '${m.provider}/${m.id}'];

const List<ModelSummary> pickerModels = [
  ModelSummary(provider: 'anthropic', id: 'claude-sonnet-4', name: 'Claude Sonnet 4'),
  ModelSummary(provider: 'openai', id: 'gpt-5', name: 'GPT-5'),
  ModelSummary(provider: 'openrouter', id: 'deepseek-chat', name: 'DeepSeek Chat'),
];

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

  testWidgets('the menu offers a model item', (tester) async {
    await tester.pumpWidget(menuHost());
    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();

    expect(find.text('Model'), findsOneWidget);
  });

  testWidgets('the menu shows the current model name', (tester) async {
    await tester.pumpWidget(menuHost(model: 'Claude Sonnet 4'));
    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const Key('session-menu-model-name')))
          .data,
      'Claude Sonnet 4',
    );
  });

  testWidgets('the menu hides the model name when none is known', (tester) async {
    await tester.pumpWidget(menuHost());
    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('session-menu-model-name')), findsNothing);
  });

  testWidgets('the menu routes the model action', (tester) async {
    final fired = <String>[];
    await tester.pumpWidget(menuHost(fired: fired));

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Model'));
    await tester.pumpAndSettle();
    expect(fired, ['model']);
  });

  testWidgets('the menu does not overflow at a large text scale with a long name', (
    tester,
  ) async {
    // A phone-sized viewport: at 2× text scale a long model name wants more
    // room than the popup item has, which must ellipsize rather than overflow.
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: menuHost(
          model: 'Claude Sonnet 4.5 with an extremely long model name indeed',
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('session-menu-model-name')), findsOneWidget);
  });

  testWidgets('the model picker marks the current model and returns the tapped one', (
    tester,
  ) async {
    ModelSummary? picked;
    await tester.pumpWidget(
      triggerHost((context) async {
        picked = await pickModel(context, const [
          ModelSummary(
            provider: 'anthropic',
            id: 'claude-sonnet-4',
            name: 'Claude Sonnet 4',
          ),
          ModelSummary(provider: 'openai', id: 'gpt-5', name: 'GPT-5'),
        ], const ModelSummary(
          provider: 'anthropic',
          id: 'claude-sonnet-4',
          name: 'Claude Sonnet 4',
        ));
      }),
    );

    await tester.tap(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('model-anthropic-claude-sonnet-4')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('model-openai-gpt-5')));
    await tester.pumpAndSettle();
    expect(picked!.id, 'gpt-5');
  });

  testWidgets('the model picker returns null when dismissed', (tester) async {
    ModelSummary? picked;
    var completed = false;
    await tester.pumpWidget(
      triggerHost((context) async {
        picked = await pickModel(context, const [
          ModelSummary(provider: 'openai', id: 'gpt-5', name: 'GPT-5'),
        ], null);
        completed = true;
      }),
    );

    await tester.tap(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('model-picker')), findsOneWidget);

    // The barrier outside the sheet dismisses it with null — the contract
    // `_setModel` relies on to treat a cancelled pick as a no-op.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(completed, isTrue);
    expect(picked, isNull);
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

  testWidgets('the model picker filters to the matching row and keeps it marked', (
    tester,
  ) async {
    await tester.pumpWidget(
      triggerHost((context) async {
        await pickModel(context, pickerModels, const ModelSummary(
          provider: 'anthropic',
          id: 'claude-sonnet-4',
          name: 'Claude Sonnet 4',
        ));
      }),
    );
    await tester.tap(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('model-search')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('model-search')), 'sonnet');
    await tester.pump();

    expect(
      find.byKey(const Key('model-anthropic-claude-sonnet-4')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('model-openai-gpt-5')), findsNothing);
    expect(find.byKey(const Key('model-openrouter-deepseek-chat')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('model-anthropic-claude-sonnet-4')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a query matching nothing shows a no-match line', (tester) async {
    await tester.pumpWidget(
      triggerHost((context) async {
        await pickModel(context, pickerModels, null);
      }),
    );
    await tester.tap(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('model-search')), 'zzz');
    await tester.pump();

    expect(find.byKey(const Key('model-picker-empty')), findsOneWidget);
    expect(find.text('No models match'), findsOneWidget);
    expect(find.byKey(const Key('model-anthropic-claude-sonnet-4')), findsNothing);
    expect(find.byKey(const Key('model-openai-gpt-5')), findsNothing);
    expect(find.byKey(const Key('model-openrouter-deepseek-chat')), findsNothing);
  });

  testWidgets('tapping a filtered row returns that model', (tester) async {
    ModelSummary? picked;
    await tester.pumpWidget(
      triggerHost((context) async {
        picked = await pickModel(context, pickerModels, null);
      }),
    );
    await tester.tap(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('model-search')), 'gpt');
    await tester.pump();
    await tester.tap(find.byKey(const Key('model-openai-gpt-5')));
    await tester.pumpAndSettle();
    expect(picked!.id, 'gpt-5');
  });

  testWidgets(
    'the model picker does not overflow at a large text scale, with typed text, and scrolls',
    (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final longModels = List<ModelSummary>.generate(
        12,
        (i) => ModelSummary(provider: 'p$i', id: 'm$i', name: 'Model $i'),
      );
      ModelSummary? picked;
      await tester.pumpWidget(
        MaterialApp(
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
                  picked = await pickModel(context, longModels, null);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('trigger')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('model-search')), 'Model');
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('model-p11-m11')), findsNothing);

      await tester.scrollUntilVisible(
        find.byKey(const Key('model-p11-m11')),
        100,
        scrollable: find.descendant(
          of: find.byKey(const Key('model-picker')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('model-p11-m11')));
      await tester.pumpAndSettle();
      expect(picked!.id, 'm11');
    },
  );

  testWidgets('the model picker keeps its content below the top system inset', (
    tester,
  ) async {
    // A long list makes the sheet reach full height, and a top system inset
    // (status bar / notch) must not be overlapped. `showModalBottomSheet`
    // removes the top padding from the sheet's MediaQuery unless `useSafeArea`
    // is set, which would leave the search field at the very top of the screen.
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 120); // 40 logical px
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);

    final longModels = List<ModelSummary>.generate(
      30,
      (i) => ModelSummary(provider: 'p$i', id: 'm$i', name: 'Model $i'),
    );
    await tester.pumpWidget(
      triggerHost((context) async {
        await pickModel(context, longModels, null);
      }),
    );
    await tester.tap(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.byKey(const Key('model-search'))).dy,
      greaterThanOrEqualTo(40),
    );
  });

  group('modelsMatching', () {
    test('an empty query returns every model in order', () {
      expect(catalogIds(modelsMatching(catalog, '')), [
        'anthropic/claude-sonnet-4',
        'openai/gpt-5',
        'openrouter/deepseek-chat',
        'openrouter/qwen3',
      ]);
    });

    test('a whitespace-only query returns every model', () {
      expect(catalogIds(modelsMatching(catalog, '   ')), catalogIds(catalog));
    });

    test('an empty query returns a copy, not the caller\'s list', () {
      final src = [...catalog];
      final out = modelsMatching(src, '');
      src.clear();
      expect(out, isNotEmpty);
    });

    test('a name substring matches case-insensitively', () {
      expect(catalogIds(modelsMatching(catalog, 'sonnet')), [
        'anthropic/claude-sonnet-4',
      ]);
      expect(catalogIds(modelsMatching(catalog, 'SONNET')), [
        'anthropic/claude-sonnet-4',
      ]);
    });

    test('a provider name matches', () {
      expect(catalogIds(modelsMatching(catalog, 'openrouter')), [
        'openrouter/deepseek-chat',
        'openrouter/qwen3',
      ]);
    });

    test('an id substring matches', () {
      expect(catalogIds(modelsMatching(catalog, 'deepseek')), [
        'openrouter/deepseek-chat',
      ]);
    });

    test('a query matching nothing returns nothing', () {
      expect(modelsMatching(catalog, 'zzz'), isEmpty);
    });

    test('no models means no matches, whatever the query', () {
      for (final q in ['', '  ', 'gpt', 'zzz']) {
        expect(modelsMatching(const [], q), isEmpty);
      }
    });
  });
}
