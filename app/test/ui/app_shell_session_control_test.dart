// Session control: new, fork, tree and composer prefill.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_shell_harness.dart';

void main() {
  testWidgets('the menu hides new and fork on a hub without session-control', (
    tester,
  ) async {
    await openFirstSession(tester);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();

    // Prove the menu is genuinely open before asserting the new items are
    // absent: two `findsNothing`s also pass if the menu never opened at all.
    expect(find.byKey(const Key('session-menu-compact')), findsOneWidget);
    expect(find.byKey(const Key('session-menu-new')), findsNothing);
    expect(find.byKey(const Key('session-menu-fork')), findsNothing);
  });

  testWidgets('new session confirms before sending sessionNew', (tester) async {
    final h = await openSessionControlSession(tester);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-new')));
    await tester.pumpAndSettle();

    // The negative control: nothing is sent while the confirmation is up.
    expect(find.text('Start a new session?'), findsOneWidget);
    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'sessionNew'),
      isEmpty,
    );

    await tester.tap(find.byKey(const Key('new-session-confirm-yes')));
    await settle(tester, h.scheduler);
    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'sessionNew'),
      hasLength(1),
    );
  });

  testWidgets('cancelling new session sends nothing', (tester) async {
    final h = await openSessionControlSession(tester);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-session-confirm-no')));
    await settle(tester, h.scheduler);

    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'sessionNew'),
      isEmpty,
    );
  });

  testWidgets('a refused new session shows the error, not a success', (
    tester,
  ) async {
    final h = await openSessionControlSession(tester);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-session-confirm-yes')));
    await tester.pump();

    final newFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'sessionNew',
    );
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': newFrame['id'],
      'ok': false,
      'error': 'the session cannot be replaced',
    });
    await settle(tester, h.scheduler);
    await tester.pump();

    // A refusal must surface verbatim. A replacement's only success signal is
    // the replacement itself, so the error must be the sole SnackBar — no
    // success confirmation may accompany it.
    expect(find.text('the session cannot be replaced'), findsOneWidget);
    expect(find.text('could not start a new session'), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('fork lists the tree, shows only user nodes and sends sessionFork', (
    tester,
  ) async {
    final h = await openSessionControlSession(tester);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-fork')));
    await tester.pumpAndSettle();

    final listFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'listTree',
    );
    expect(listFrame['sessionId'], 's1');

    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
        {'id': 'e2', 'parentId': 'e1', 'role': 'assistant', 'text': 'hi'},
        {'id': 'e3', 'parentId': 'e1', 'role': 'user', 'text': 'again'},
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tree-node-e1')), findsOneWidget);
    expect(find.byKey(const Key('tree-node-e3')), findsOneWidget);
    expect(find.byKey(const Key('tree-node-e2')), findsNothing);

    await tester.tap(find.byKey(const Key('tree-node-e3')));
    await settle(tester, h.scheduler);

    final forkFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'sessionFork',
    );
    expect((forkFrame['args']! as Map)['entryId'], 'e3');
  });

  testWidgets('a refused fork shows the error', (tester) async {
    final h = await openSessionControlSession(tester);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-fork')));
    await tester.pumpAndSettle();

    final listFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'listTree',
    );
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
      ]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tree-node-e1')));
    await settle(tester, h.scheduler);

    final forkFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'sessionFork',
    );
    // The entry was invalidated between listing the tree and sending the fork
    // (the plan's FM5): the bridge refuses it and the refusal must reach the
    // screen, not vanish into the awaited replacement.
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': forkFrame['id'],
      'ok': false,
      'error': 'unknown entry',
    });
    await settle(tester, h.scheduler);
    await tester.pump();

    expect(find.text('unknown entry'), findsOneWidget);
    expect(find.text('could not fork the session'), findsNothing);
  });

  testWidgets('a refused tree list shows the error, not an empty sheet', (
    tester,
  ) async {
    final h = await openSessionControlSession(tester);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-fork')));
    await tester.pumpAndSettle();

    final listFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'listTree',
    );
    h.factory.last.receive(
      treeReply(
        listFrame['id']! as String,
        const [],
        ok: false,
        error: 'cannot read the tree',
      ),
    );
    await settle(tester, h.scheduler);
    await tester.pump();

    expect(find.byKey(const Key('tree-picker')), findsNothing);
    expect(find.text('cannot read the tree'), findsOneWidget);
  });

  testWidgets('the menu hides Tree on a hub without session-control', (
    tester,
  ) async {
    await openFirstSession(tester);
    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    // Prove the menu is open before asserting absence.
    expect(find.byKey(const Key('session-menu-compact')), findsOneWidget);
    expect(find.byKey(const Key('session-menu-tree')), findsNothing);
  });

  testWidgets('the menu shows and routes Tree with session-control', (
    tester,
  ) async {
    final h = await openSessionControlSession(tester);
    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-menu-tree')), findsOneWidget);

    await tester.tap(find.byKey(const Key('session-menu-tree')));
    await tester.pumpAndSettle();
    // Routing proof: the item issues a listTree.
    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'listTree'),
      hasLength(1),
    );
  });

  testWidgets('Tree lists all nodes and marks the current leaf', (tester) async {
    final h = await openSessionControlSession(tester);
    final listFrame = await tapTreeItem(tester, h);
    expect(listFrame['sessionId'], 's1');

    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
        {'id': 'e2', 'parentId': 'e1', 'role': 'assistant', 'text': 'hi'},
        {'id': 'e3', 'parentId': 'e2', 'role': 'user', 'text': 'again'},
      ], leafId: 'e2'),
    );
    await tester.pumpAndSettle();

    // The Tree picker offers assistant nodes too (Fork keeps them out).
    expect(find.byKey(const Key('tree-node-e1')), findsOneWidget);
    expect(find.byKey(const Key('tree-node-e2')), findsOneWidget);
    expect(find.byKey(const Key('tree-node-e3')), findsOneWidget);
    expect(find.byKey(const Key('tree-node-current-e2')), findsOneWidget);
    expect(find.byKey(const Key('tree-node-current-e1')), findsNothing);
  });

  testWidgets(
    'tapping the current leaf sends no command and says already there',
    (tester) async {
      final h = await openSessionControlSession(tester);
      final listFrame = await tapTreeItem(tester, h);
      h.factory.last.receive(
        treeReply(listFrame['id']! as String, [
          {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
          {'id': 'e3', 'parentId': 'e1', 'role': 'user', 'text': 'again'},
        ], leafId: 'e1'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('tree-node-e1')));
      await settle(tester, h.scheduler);

      // pi emits nothing for a same-leaf target, so a frame here would look
      // like a failure: the guard is local and sends nothing.
      expect(
        h.factory.last.sentFrames.where((f) => f['name'] == 'sessionTree'),
        isEmpty,
      );
      expect(find.text('Already at this point'), findsOneWidget);
    },
  );

  testWidgets(
    'tapping another node sends sessionTree, requests no history and shows no error',
    (tester) async {
      final h = await openSessionControlSession(tester);
      final listFrame = await tapTreeItem(tester, h);
      h.factory.last.receive(
        treeReply(listFrame['id']! as String, [
          {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
          {'id': 'e3', 'parentId': 'e1', 'role': 'user', 'text': 'again'},
        ], leafId: 'e1'),
      );
      await tester.pumpAndSettle();

      final requestsBefore = h.factory.last.sentFrames
          .where((f) => f['type'] == 'history-request')
          .length;

      await tester.tap(find.byKey(const Key('tree-node-e3')));
      await settle(tester, h.scheduler);

      final treeFrame = h.factory.last.sentFrames.lastWhere(
        (f) => f['name'] == 'sessionTree',
      );
      expect((treeFrame['args']! as Map)['entryId'], 'e3');

      h.factory.last.receive({
        'protocolVersion': 1,
        'type': 'command-result',
        'id': treeFrame['id'],
        'ok': true,
      });
      await settle(tester, h.scheduler);
      await tester.pump();

      // Checked after the ack: a request issued either right after the send or
      // on the ack both have to fail. The leaf event is the sole trigger.
      expect(
        h.factory.last.sentFrames
            .where((f) => f['type'] == 'history-request')
            .length,
        requestsBefore,
        reason: 'the leaf event is the sole re-baseline trigger',
      );

      // A successful navigation is silent: an unconditional SnackBar would
      // otherwise pass this and the refusal test together.
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets('a leaf event after a navigation re-requests history', (
    tester,
  ) async {
    final h = await openSessionControlSession(tester);
    final listFrame = await tapTreeItem(tester, h);
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
        {'id': 'e3', 'parentId': 'e1', 'role': 'user', 'text': 'again'},
      ], leafId: 'e1'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tree-node-e3')));
    await settle(tester, h.scheduler);
    await ackSessionTree(tester, h);

    final requestsBefore = h.factory.last.sentFrames
        .where((f) => f['type'] == 'history-request')
        .length;

    h.factory.last.receive(leafFrame('e1'));
    await settle(tester, h.scheduler);

    final requests = h.factory.last.sentFrames
        .where((f) => f['type'] == 'history-request')
        .toList();
    expect(requests.length, requestsBefore + 1);
    expect(requests.last['sessionId'], 's1');
  });

  testWidgets('a user node prefills the composer when empty', (tester) async {
    final h = await openSessionControlSession(tester);
    final listFrame = await tapTreeItem(tester, h);
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
      ], leafId: 'e3'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tree-node-e1')));
    await settle(tester, h.scheduler);
    await ackSessionTree(tester, h);

    // The ack is "accepted", not "navigated": prefill waits for the leaf.
    h.factory.last.receive(leafFrame('e3'));
    await settle(tester, h.scheduler);

    expect(composeText(tester), 'hello');
  });

  testWidgets('a non-empty composer is not overwritten', (tester) async {
    final h = await openSessionControlSession(tester);
    await tester.enterText(find.byKey(const Key('compose-field')), 'draft');

    final listFrame = await tapTreeItem(tester, h);
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
      ], leafId: 'e3'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tree-node-e1')));
    await settle(tester, h.scheduler);
    await ackSessionTree(tester, h);
    h.factory.last.receive(leafFrame('e3'));
    await settle(tester, h.scheduler);

    // pi restores the text only into an empty editor; a draft wins.
    expect(composeText(tester), 'draft');
  });

  testWidgets('an assistant node does not prefill the composer', (tester) async {
    final h = await openSessionControlSession(tester);
    final listFrame = await tapTreeItem(tester, h);
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
        {'id': 'e2', 'parentId': 'e1', 'role': 'assistant', 'text': 'hi'},
      ], leafId: 'e1'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tree-node-e2')));
    await settle(tester, h.scheduler);
    await ackSessionTree(tester, h);
    h.factory.last.receive(leafFrame('e1'));
    await settle(tester, h.scheduler);

    expect(composeText(tester), isEmpty);
  });

  testWidgets('a refused sessionTree shows the error and prefills nothing', (
    tester,
  ) async {
    final h = await openSessionControlSession(tester);
    final listFrame = await tapTreeItem(tester, h);
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
      ], leafId: 'e3'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tree-node-e1')));
    await settle(tester, h.scheduler);

    final treeFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'sessionTree',
    );
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': treeFrame['id'],
      'ok': false,
      'error': 'cannot navigate the tree while pi is working',
    });
    await settle(tester, h.scheduler);
    await tester.pump();

    expect(
      find.text('cannot navigate the tree while pi is working'),
      findsOneWidget,
    );
    // A refusal clears the pending tap: a later leaf must not prefill it.
    h.factory.last.receive(leafFrame('e3'));
    await settle(tester, h.scheduler);
    expect(composeText(tester), isEmpty);
  });

  testWidgets('an ack alone does not prefill', (tester) async {
    final h = await openSessionControlSession(tester);
    final listFrame = await tapTreeItem(tester, h);
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
      ], leafId: 'e3'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tree-node-e1')));
    await settle(tester, h.scheduler);
    await ackSessionTree(tester, h);

    // No leaf event: the navigation is not known to have happened.
    expect(composeText(tester), isEmpty);
  });

  testWidgets('a post-ack failure reports the error and does not prefill', (
    tester,
  ) async {
    final h = await openSessionControlSession(tester);
    final listFrame = await tapTreeItem(tester, h);
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
      ], leafId: 'e3'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tree-node-e1')));
    await settle(tester, h.scheduler);
    await ackSessionTree(tester, h);

    // The navigation fails after the ack, as a status error, with no leaf.
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {
        'kind': 'status',
        'event': 'error',
        'message': 'cannot navigate the tree',
      },
    });
    await settle(tester, h.scheduler);
    await tester.pump();

    expect(find.text('cannot navigate the tree'), findsOneWidget);
    expect(composeText(tester), isEmpty);
  });

  testWidgets('a stale same-leaf tap is silent and prefills nothing', (
    tester,
  ) async {
    final h = await openSessionControlSession(tester);
    final listFrame = await tapTreeItem(tester, h);
    // listTree says the leaf is e1, but pi's leaf has since moved to e2.
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
        {'id': 'e2', 'parentId': 'e1', 'role': 'user', 'text': 'again'},
      ], leafId: 'e1'),
    );
    await tester.pumpAndSettle();

    // The tap is not the listed leaf (e1), so the local guard cannot catch it;
    // at pi it really is the current leaf, which early-returns with no event.
    await tester.tap(find.byKey(const Key('tree-node-e2')));
    await settle(tester, h.scheduler);
    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'sessionTree'),
      hasLength(1),
    );
    await ackSessionTree(tester, h);

    await tester.pump();
    expect(composeText(tester), isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });
}
