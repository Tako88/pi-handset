/// The ⋮ menu's fork and tree-navigation actions, lifted out of the app shell.
///
/// Both list the session tree, show a picker, and send the command. A navigate
/// arms a single-slot pending tap that the shell consumes when pi's `leaf`
/// event proves the move actually ran. A pure action layer: all it needs from
/// the shell is the client, a liveness probe, and the arm/disarm callbacks for
/// the shell-owned pending tap.
library;

import 'package:flutter/material.dart';

import '../client/hub_client_view.dart';
import 'session_menu.dart';

/// The ⋮ menu's fork and tree-navigation actions.
class TreeActions {
  TreeActions({required this.client, required this.isMounted});

  final HubClientView client;

  /// Whether the owning State is still mounted. Read at each guard point, at
  /// the position the shell's own `mounted` checks held.
  final bool Function() isMounted;

  /// Lists the session tree, shows only user nodes, and forks at the picked one.
  /// `context.mounted` after the list await, because the picker needs the
  /// descendant context alive — the same check `setModel` makes.
  Future<void> fork(String activeId, BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final listed = await client.listTree(activeId);
    if (!context.mounted) return;
    if (!listed.ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(listed.error ?? 'could not read the session tree'),
        ),
      );
      return;
    }
    final picked = await pickTreeNode(
      context,
      listed.tree ?? const <TreeNodeSummary>[],
      userOnly: true,
      truncated: listed.treeTruncated ?? false,
    );
    if (!isMounted() || picked == null) return;
    final result = await client.sessionFork(activeId, picked.id);
    if (!isMounted() || result.ok) return;
    messenger.showSnackBar(
      SnackBar(content: Text(result.error ?? 'could not fork the session')),
    );
  }

  /// Lists the whole session tree, marks pi's current leaf, and moves the leaf
  /// to the picked node. `context.mounted` after the list await, because the
  /// picker needs the descendant context alive — the same check `fork` makes.
  ///
  /// The `sessionTree` ack means accepted, not navigated, so this never
  /// prefills and never re-requests history here: the shell's leaf handler does
  /// both when pi's `leaf` event arrives. A request issued now would race the
  /// move and could return the old branch.
  Future<void> navigate(
    String activeId,
    BuildContext context, {
    required void Function(PendingTreeTap) arm,
    required void Function() disarm,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final listed = await client.listTree(activeId);
    if (!context.mounted) return;
    if (!listed.ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(listed.error ?? 'could not read the session tree'),
        ),
      );
      return;
    }
    final picked = await pickTreeNode(
      context,
      listed.tree ?? const <TreeNodeSummary>[],
      userOnly: false,
      truncated: listed.treeTruncated ?? false,
      leafId: listed.leafId,
    );
    if (!isMounted() || picked == null) return;
    // pi returns early for a same-leaf target before it emits, so a tap sent
    // for the current point would produce no `leaf` event and look like a
    // failure. Answer it locally instead.
    if (picked.id == listed.leafId) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Already at this point')),
      );
      return;
    }
    arm(PendingTreeTap(sessionId: activeId, node: picked));
    final result = await client.sessionTree(activeId, picked.id);
    if (!isMounted()) return;
    if (!result.ok) {
      // A dispatch-time refusal never navigates, so drop the armed tap rather
      // than let a later, unrelated leaf prefill it.
      disarm();
      messenger.showSnackBar(
        SnackBar(content: Text(result.error ?? 'could not navigate the tree')),
      );
    }
  }
}

/// A tree node the user tapped, waiting for the `leaf` event that proves pi
/// navigated to it. Carries its session so a leaf for another session cannot
/// consume it.
class PendingTreeTap {
  final String sessionId;
  final TreeNodeSummary node;

  const PendingTreeTap({required this.sessionId, required this.node});
}
