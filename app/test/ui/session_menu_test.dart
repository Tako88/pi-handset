// The transcript menu's widgets: the ⋮ button, and the compact / rename /
// thinking-level dialogs. The observable is what the user sees or taps, plus
// each dialog's return value.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/ui/session_menu.dart';
import 'package:pi_droid/ui/theme.dart';

/// A host whose app bar carries the menu. Callbacks record what fired.
///
/// `onNewSession`/`onFork` are null by default, which stands in for a hub
/// without the `session-control` capability.
Widget menuHost({
  String? thinkingLevel,
  String? model,
  bool sessionControl = false,
  bool muted = false,
  List<String>? fired,
}) => MaterialApp(
  theme: piTheme(Brightness.dark),
  home: Scaffold(
    appBar: AppBar(
      actions: [
        SessionMenuButton(
          thinkingLevel: thinkingLevel,
          model: model,
          muted: muted,
          onCompact: () => fired?.add('compact'),
          onRename: () => fired?.add('rename'),
          onThinkingLevel: () => fired?.add('thinking'),
          onModel: () => fired?.add('model'),
          onNewSession: sessionControl ? () => fired?.add('new') : null,
          onFork: sessionControl ? () => fired?.add('fork') : null,
          onToggleNotify: () => fired?.add('notify'),
        ),
      ],
    ),
  ),
);

/// A host with a single button that opens [open] and records its result.
Widget triggerHost(Future<void> Function(BuildContext context) open) =>
    MaterialApp(
      theme: piTheme(Brightness.dark),
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

/// The left content padding of a rendered tree row, in logical pixels.
double treeRowLeft(WidgetTester tester, String id) {
  final tile = tester.widget<ListTile>(find.byKey(Key('tree-node-$id')));
  return (tile.contentPadding! as EdgeInsets).left;
}

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

  testWidgets('the menu hides new and fork without the session-control capability', (
    tester,
  ) async {
    await tester.pumpWidget(menuHost());
    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();

    // Prove the menu is genuinely open before asserting the new items are
    // absent: two `findsNothing`s also pass if the menu never opened at all.
    expect(find.byKey(const Key('session-menu-compact')), findsOneWidget);
    expect(find.byKey(const Key('session-menu-new')), findsNothing);
    expect(find.byKey(const Key('session-menu-fork')), findsNothing);
  });

  testWidgets('the menu shows new and fork with the session-control capability', (
    tester,
  ) async {
    await tester.pumpWidget(menuHost(sessionControl: true));
    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('session-menu-new')), findsOneWidget);
    expect(find.byKey(const Key('session-menu-fork')), findsOneWidget);
  });

  testWidgets('the menu routes the new and fork actions', (tester) async {
    final fired = <String>[];
    await tester.pumpWidget(menuHost(sessionControl: true, fired: fired));

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-new')));
    await tester.pumpAndSettle();
    expect(fired, ['new']);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-fork')));
    await tester.pumpAndSettle();
    expect(fired, ['new', 'fork']);
  });

  testWidgets('the menu shows a Mute item', (tester) async {
    await tester.pumpWidget(menuHost());
    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('session-menu-notify')), findsOneWidget);
    expect(find.text('Mute'), findsOneWidget);
  });

  testWidgets('the mute item reads Unmute when the session is muted', (
    tester,
  ) async {
    await tester.pumpWidget(menuHost(muted: true));
    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();

    expect(find.text('Unmute'), findsOneWidget);
    expect(find.text('Mute'), findsNothing);
  });

  testWidgets('tapping the mute item fires onToggleNotify', (tester) async {
    final fired = <String>[];
    await tester.pumpWidget(menuHost(fired: fired));

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-notify')));
    await tester.pumpAndSettle();

    expect(fired, ['notify']);
  });

  testWidgets('the menu does not overflow at a large text scale with new and fork', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: menuHost(
          sessionControl: true,
          model: 'Claude Sonnet 4.5 with an extremely long model name indeed',
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('session-menu-new')), findsOneWidget);
    expect(find.byKey(const Key('session-menu-fork')), findsOneWidget);
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
        theme: piTheme(Brightness.dark),
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
          theme: piTheme(Brightness.dark),
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

  group('pickTreeNode', () {
    const treeNodes = [
      TreeNodeSummary(
        id: 'e1',
        parentId: null,
        role: 'user',
        text: 'first question',
      ),
      TreeNodeSummary(
        id: 'e2',
        parentId: 'e1',
        role: 'assistant',
        text: 'an answer',
      ),
      TreeNodeSummary(
        id: 'e3',
        parentId: 'e1',
        role: 'user',
        text: 'a follow-up',
      ),
    ];

    testWidgets('returns the tapped node', (tester) async {
      TreeNodeSummary? picked;
      await tester.pumpWidget(
        triggerHost((context) async {
          picked = await pickTreeNode(context, treeNodes, userOnly: true);
        }),
      );
      await tester.tap(find.byKey(const Key('trigger')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tree-picker')), findsOneWidget);
      await tester.tap(find.byKey(const Key('tree-node-e3')));
      await tester.pumpAndSettle();
      expect(picked!.id, 'e3');
    });

    testWidgets('returns null when dismissed', (tester) async {
      TreeNodeSummary? picked;
      var completed = false;
      await tester.pumpWidget(
        triggerHost((context) async {
          picked = await pickTreeNode(context, treeNodes, userOnly: true);
          completed = true;
        }),
      );
      await tester.tap(find.byKey(const Key('trigger')));
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(completed, isTrue);
      expect(picked, isNull);
    });

    testWidgets('keeps only user nodes under userOnly', (tester) async {
      await tester.pumpWidget(
        triggerHost((context) async {
          await pickTreeNode(context, treeNodes, userOnly: true);
        }),
      );
      await tester.tap(find.byKey(const Key('trigger')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tree-node-e1')), findsOneWidget);
      expect(find.byKey(const Key('tree-node-e3')), findsOneWidget);
      expect(find.byKey(const Key('tree-node-e2')), findsNothing);
    });

    testWidgets('keeps every node without userOnly', (tester) async {
      await tester.pumpWidget(
        triggerHost((context) async {
          await pickTreeNode(context, treeNodes, userOnly: false);
        }),
      );
      await tester.tap(find.byKey(const Key('trigger')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tree-node-e1')), findsOneWidget);
      expect(find.byKey(const Key('tree-node-e2')), findsOneWidget);
      expect(find.byKey(const Key('tree-node-e3')), findsOneWidget);
    });

    testWidgets('marks the current leaf and leaves other rows unmarked', (
      tester,
    ) async {
      await tester.pumpWidget(
        triggerHost((context) async {
          await pickTreeNode(
            context,
            treeNodes,
            userOnly: false,
            leafId: 'e2',
          );
        }),
      );
      await tester.tap(find.byKey(const Key('trigger')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tree-node-current-e2')), findsOneWidget);
      expect(find.byKey(const Key('tree-node-current-e1')), findsNothing);
      expect(find.byKey(const Key('tree-node-current-e3')), findsNothing);
    });

    testWidgets('marks nothing when no leaf is given', (tester) async {
      await tester.pumpWidget(
        triggerHost((context) async {
          await pickTreeNode(context, treeNodes, userOnly: true);
        }),
      );
      await tester.tap(find.byKey(const Key('trigger')));
      await tester.pumpAndSettle();

      // Prove the picker rendered before asserting no row is marked: a
      // never-opened picker also satisfies a lone `findsNothing`.
      expect(find.byKey(const Key('tree-node-e1')), findsOneWidget);
      expect(find.byKey(const Key('tree-node-current-e1')), findsNothing);
      expect(find.byKey(const Key('tree-node-current-e3')), findsNothing);
    });

    testWidgets('shows the empty state when nothing qualifies', (tester) async {
      await tester.pumpWidget(
        triggerHost((context) async {
          await pickTreeNode(
            context,
            const [
              TreeNodeSummary(
                id: 'e1',
                parentId: null,
                role: 'assistant',
                text: 'an answer',
              ),
            ],
            userOnly: true,
          );
        }),
      );
      await tester.tap(find.byKey(const Key('trigger')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tree-picker-empty')), findsOneWidget);
      expect(find.byKey(const Key('tree-node-e1')), findsNothing);
    });

    testWidgets('shows the truncated note when told', (tester) async {
      await tester.pumpWidget(
        triggerHost((context) async {
          await pickTreeNode(
            context,
            treeNodes,
            userOnly: true,
            truncated: true,
          );
        }),
      );
      await tester.tap(find.byKey(const Key('trigger')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tree-picker-truncated')), findsOneWidget);
    });

    testWidgets('does not overflow at a large text scale and scrolls', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final many = [
        for (var i = 0; i < 20; i++)
          TreeNodeSummary(
            id: 'e$i',
            parentId: i == 0 ? null : 'e${i - 1}',
            role: 'user',
            text: 'message number $i',
          ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: piTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                key: const Key('trigger'),
                onPressed: () async {
                  await pickTreeNode(context, many, userOnly: true);
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

      // The last row is not built until it is scrolled into view, which proves
      // the list scrolls inside the sheet rather than overflowing it.
      expect(find.byKey(const Key('tree-node-e19')), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('tree-node-e19')),
        100,
        scrollable: find.descendant(
          of: find.byKey(const Key('tree-picker')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tree-node-e19')), findsOneWidget);
    });

    testWidgets('hides the truncated note when nothing was dropped', (
      tester,
    ) async {
      await tester.pumpWidget(
        triggerHost((context) async {
          await pickTreeNode(context, treeNodes, userOnly: true);
        }),
      );
      await tester.tap(find.byKey(const Key('trigger')));
      await tester.pumpAndSettle();

      // Prove the picker rendered before asserting the note is absent: only a
      // never-opened picker also satisfies a lone `findsNothing`.
      expect(find.byKey(const Key('tree-node-e1')), findsOneWidget);
      expect(find.byKey(const Key('tree-picker-truncated')), findsNothing);
    });

    testWidgets('a straight chain keeps every row at the same indent', (
      tester,
    ) async {
      // The regression witness: in an ordinary conversation every message is
      // the child of the previous one, so a depth-based indent marches right by
      // one step per row until the label has no room left. A tall viewport so
      // the whole dozen rows are built and readable in one pass.
      tester.view.physicalSize = const Size(360 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final chain = [
        for (var i = 0; i < 12; i++)
          TreeNodeSummary(
            id: 'c$i',
            parentId: i == 0 ? null : 'c${i - 1}',
            role: 'user',
            text: 'message number $i',
          ),
      ];
      await tester.pumpWidget(
        triggerHost((context) async {
          await pickTreeNode(context, chain, userOnly: false);
        }),
      );
      await tester.tap(find.byKey(const Key('trigger')));
      await tester.pumpAndSettle();

      final first = treeRowLeft(tester, 'c0');
      for (var i = 1; i < 12; i++) {
        expect(
          treeRowLeft(tester, 'c$i'),
          first,
          reason: 'row c$i must stay level with the chain, not drift right',
        );
      }
    });

    testWidgets('a fork indents both branches, then each branch stays flat', (
      tester,
    ) async {
      // The rendered counterpart to the branch rule: only the fork steps rows
      // in. Base padding is 16dp, so indent i renders at 16 + 16 * i.
      tester.view.physicalSize = const Size(360 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const fork = [
        TreeNodeSummary(id: 'r', parentId: null, role: 'user', text: 'root'),
        TreeNodeSummary(id: 'a', parentId: 'r', role: 'assistant', text: 'a'),
        TreeNodeSummary(id: 'a1', parentId: 'a', role: 'user', text: 'a1'),
        TreeNodeSummary(id: 'a2', parentId: 'a1', role: 'user', text: 'a2'),
        TreeNodeSummary(id: 'b', parentId: 'r', role: 'assistant', text: 'b'),
        TreeNodeSummary(id: 'b1', parentId: 'b', role: 'user', text: 'b1'),
        TreeNodeSummary(id: 'b2', parentId: 'b1', role: 'user', text: 'b2'),
      ];
      await tester.pumpWidget(
        triggerHost((context) async {
          await pickTreeNode(context, fork, userOnly: false);
        }),
      );
      await tester.tap(find.byKey(const Key('trigger')));
      await tester.pumpAndSettle();

      // r branches, so both branches step in (32). Each branch's first child
      // takes pi's extra "visual grouping" step (48), then stays flat.
      expect(treeRowLeft(tester, 'r'), 16);
      expect(treeRowLeft(tester, 'a'), 32);
      expect(treeRowLeft(tester, 'a1'), 48);
      expect(treeRowLeft(tester, 'a2'), 48);
      expect(treeRowLeft(tester, 'b'), 32);
      expect(treeRowLeft(tester, 'b1'), 48);
      expect(treeRowLeft(tester, 'b2'), 48);
    });

    testWidgets('the userOnly Fork path lists only user nodes and marks none', (
      tester,
    ) async {
      // A pin: this is the Fork call exactly as the shell makes it
      // (`userOnly: true`, no leafId), and neither half may drift.
      await tester.pumpWidget(
        triggerHost((context) async {
          await pickTreeNode(context, treeNodes, userOnly: true);
        }),
      );
      await tester.tap(find.byKey(const Key('trigger')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tree-node-e1')), findsOneWidget);
      expect(find.byKey(const Key('tree-node-e3')), findsOneWidget);
      // e2 is the assistant turn: the Fork list offers user messages only.
      expect(find.byKey(const Key('tree-node-e2')), findsNothing);
      expect(find.byKey(const Key('tree-node-current-e1')), findsNothing);
      expect(find.byKey(const Key('tree-node-current-e3')), findsNothing);
    });
  });

  group('treeIndents', () {
    test('the indent never exceeds treeMaxIndent however deep the history goes', () {
      // A spine whose every node also sprouts a second child, so each
      // generation would step in one further. Ten generations is well past the
      // cap, and the maximum must sit exactly on it, so the clamp is exercised
      // rather than merely never reached.
      final nodes = <TreeNodeSummary>[
        const TreeNodeSummary(
          id: 'n0',
          parentId: null,
          role: 'user',
          text: 'n0',
        ),
      ];
      for (var i = 1; i <= 10; i++) {
        nodes.add(
          TreeNodeSummary(
            id: 'n$i',
            parentId: 'n${i - 1}',
            role: 'user',
            text: 'n$i',
          ),
        );
        nodes.add(
          TreeNodeSummary(
            id: 'leaf$i',
            parentId: 'n${i - 1}',
            role: 'assistant',
            text: 'leaf$i',
          ),
        );
      }

      final indents = treeIndents(nodes);
      expect(indents.reduce((a, b) => a > b ? a : b), treeMaxIndent);
      for (final indent in indents) {
        expect(indent, lessThanOrEqualTo(treeMaxIndent));
      }
    });

    test('an orphaned parent reads as a root and several roots branch', () {
      const nodes = [
        TreeNodeSummary(id: 'e1', parentId: null, role: 'user', text: 'e1'),
        TreeNodeSummary(id: 'e2', parentId: 'e1', role: 'user', text: 'e2'),
        // 'ghost' was dropped by the node cap, so the bridge relinked this node
        // to the root; it must read as a root, not vanish.
        TreeNodeSummary(
          id: 'orphan',
          parentId: 'ghost',
          role: 'user',
          text: 'orphan',
        ),
        TreeNodeSummary(
          id: 'orphanChild',
          parentId: 'orphan',
          role: 'user',
          text: 'orphanChild',
        ),
      ];

      // Two roots: pi treats them as children of a virtual root that branches,
      // so each root starts one step in and its single-child chain takes the
      // extra step then stays flat.
      expect(treeIndents(nodes), [1, 2, 1, 2]);
    });
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
