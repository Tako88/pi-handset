/// The transcript's app bar: the session title (or the find-in-transcript
/// query field) and the session menu.
///
/// A real [AppBar] behind [PreferredSizeWidget], at [AppBar]'s own height, so
/// a caller that reads `tester.widget<AppBar>(...).actions` still finds it.
library;

import 'package:flutter/material.dart';

import '../client/context_usage.dart';
import '../client/hub_models.dart';
import 'session_menu.dart';
import 'theme.dart';
import 'transcript_search_controller.dart';

class TranscriptAppBar extends StatelessWidget implements PreferredSizeWidget {
  const TranscriptAppBar({
    super.key,
    required this.transcript,
    required this.sessionName,
    required this.search,
    required this.muted,
    required this.onToggleNotify,
    required this.onCompact,
    required this.onRename,
    required this.onThinkingLevel,
    required this.onModel,
    this.onNewSession,
    this.onFork,
    this.onTree,
    required this.onBack,
  });

  /// The active session's transcript: its thinking level, current model and
  /// context reading.
  final SessionTranscript transcript;

  /// The active session's label, shown as the title when the search is closed.
  final String sessionName;

  /// The find-in-transcript state: whether the field is open, the matches, the
  /// current match, and the query field's controller and focus.
  final TranscriptSearchController search;

  /// Whether the active session's notifications are muted.
  final bool muted;

  /// Flips the active session's muted flag.
  final VoidCallback onToggleNotify;

  final VoidCallback onCompact;
  final VoidCallback onRename;
  final VoidCallback onThinkingLevel;
  final VoidCallback onModel;

  /// Replaces the session with a fresh one. Null (no `session-control`
  /// capability) hides the item.
  final VoidCallback? onNewSession;

  /// Replaces the session with a fork of it. Null hides the item.
  final VoidCallback? onFork;

  /// Moves the session's leaf to a picked node. Null hides the item.
  final VoidCallback? onTree;

  /// Pops the transcript route back to the session list.
  final VoidCallback onBack;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final matches = search.matchesFor(transcript.blocks);
    final currentIndex = search.currentIndex(matches);
    return AppBar(
      title: search.open ? _searchField() : _transcriptTitle(),
      leading: search.open
          ? IconButton(
              key: const Key('transcript-search-close'),
              icon: const Icon(Icons.close),
              onPressed: search.closeSearch,
              tooltip: 'Close search',
            )
          : IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: onBack,
              tooltip: 'Sessions',
            ),
      actions: search.open
          ? [
              _searchCount(currentIndex, matches.length),
              IconButton(
                key: const Key('transcript-search-prev'),
                icon: const Icon(Icons.keyboard_arrow_up),
                onPressed: matches.isEmpty
                    ? null
                    : () => search.step(-1, matches),
                tooltip: 'Previous match',
              ),
              IconButton(
                key: const Key('transcript-search-next'),
                icon: const Icon(Icons.keyboard_arrow_down),
                onPressed: matches.isEmpty
                    ? null
                    : () => search.step(1, matches),
                tooltip: 'Next match',
              ),
            ]
          : [
              IconButton(
                key: const Key('transcript-search'),
                icon: const Icon(Icons.search),
                onPressed: search.openSearch,
                tooltip: 'Search transcript',
              ),
              SessionMenuButton(
                muted: muted,
                onToggleNotify: onToggleNotify,
                thinkingLevel: transcript.thinkingLevel,
                model: transcript.currentModel?.name,
                onCompact: onCompact,
                onRename: onRename,
                onThinkingLevel: onThinkingLevel,
                onModel: onModel,
                // New and fork replace the session: only a hub advertising
                // the capability can, and without it the items are omitted
                // rather than offered and refused.
                onNewSession: onNewSession,
                onFork: onFork,
                onTree: onTree,
              ),
            ],
    );
  }

  /// The transcript's title: the session name plus the context reading.
  ///
  /// The reading takes priority over the name: the name is a reminder of which
  /// session this is, while the reading is a number you cannot guess from
  /// anything else on screen. So the name is the flexible half, and it is the
  /// one that gets cut when the two compete for room.
  ///
  /// The reading is laid out before the name (non-flex children are measured
  /// first) and is never ellipsized. At a large text scale it can want more
  /// room than the title has at all, which would overflow the row — so it is
  /// capped to the available width and scaled down rather than truncated: a
  /// slightly smaller number beats a cut-off one.
  Widget _transcriptTitle() {
    final usage = transcript.contextUsage;
    final usageLabel = usage == null ? null : formatContextUsage(usage);
    // A running compaction takes the reading's slot: the number is exactly what
    // the compaction is about to invalidate, and an app bar that sits unchanged
    // for the length of a summarization call reads as a hang.
    final barLabel = transcript.compacting ? 'Compacting…' : usageLabel;
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          Expanded(
            child: Text(
              sessionName,
              key: const Key('session-name'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // The session's name is a session's name, not prose: the app bar
              // speaks in the machine's voice, like every other label that
              // names a thing.
              style: piMono(fontSize: 13),
            ),
          ),
          if (barLabel != null)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              // The gap lives inside the cap, so the padding cannot push the
              // row past the width the label was measured against.
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    barLabel,
                    key: Key(
                      transcript.compacting ? 'compacting' : 'context-usage',
                    ),
                    maxLines: 1,
                    softWrap: false,
                    style: piMono(fontSize: 12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The find-in-transcript query field, shown in place of the title.
  Widget _searchField() => TextField(
    key: const Key('transcript-search-field'),
    controller: search.controller,
    focusNode: search.focus,
    // Any edit re-anchors the current match to the first hit.
    onChanged: (_) => search.queryChanged(),
    decoration: const InputDecoration(
      hintText: 'Search transcript',
      border: InputBorder.none,
    ),
  );

  /// The counted n/N readout. The KEY is the contract, not its slot: at a large
  /// text scale this can move into the field's `suffixText` (same key) if it
  /// overflows the bar.
  Widget _searchCount(int currentIndex, int total) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        total == 0 ? '0/0' : '${currentIndex + 1}/$total',
        key: const Key('transcript-search-count'),
        style: piMono(fontSize: 12),
      ),
    ),
  );
}
