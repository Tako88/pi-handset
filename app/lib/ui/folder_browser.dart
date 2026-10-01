/// The folder browser.
///
/// Lists directories under the hub's browse root and lets the user walk into
/// one and start a session there. A pushed route, so `Navigator.pop` on success
/// returns to the session list.
///
/// The listing itself is the client's: this widget only renders the snapshot it
/// gets back from `listDirs` and reports navigation taps. The trust prompt
/// appears only when the hub says the folder requires a decision and none is
/// stored — pi's own rule.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../client/hub_client.dart';

class FolderBrowserScreen extends StatefulWidget {
  const FolderBrowserScreen({super.key, required this.client});

  final HubClient client;

  @override
  State<FolderBrowserScreen> createState() => _FolderBrowserScreenState();
}

class _FolderBrowserScreenState extends State<FolderBrowserScreen> {
  DirListing? _listing;
  String? _error;
  bool _loading = true;

  /// Monotonic request id: only the newest `list-dirs` may write the listing, so
  /// a slow reply to an abandoned navigation cannot overwrite a newer one.
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load(null));
  }

  Future<void> _load(String? path) async {
    final seq = ++_seq;
    final result = await widget.client.listDirs(path: path);
    if (!mounted || seq != _seq) return;
    setState(() {
      _loading = false;
      if (result.ok && result.listing != null) {
        _listing = result.listing;
        _error = null;
      } else {
        _error = result.error ?? 'could not list the folder';
      }
    });
  }

  void _open(String path) {
    setState(() {
      _loading = true;
      _error = null;
    });
    unawaited(_load(path));
  }

  void _up() {
    final listing = _listing;
    if (listing == null || _isAtRoot(listing)) return;
    _open(_parentOf(listing.path));
  }

  Future<void> _startHere() async {
    final listing = _listing;
    if (listing == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    bool? trust;
    if (listing.trust == null && listing.trustRequired) {
      final decision = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Trust this folder?'),
          content: const Text(
            'This folder has project settings or extensions that can run code.',
          ),
          actions: [
            TextButton(
              key: const Key('trust-no'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Do not trust'),
            ),
            TextButton(
              key: const Key('trust-yes'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Trust'),
            ),
          ],
        ),
      );
      if (!mounted || decision == null) return;
      trust = decision;
    }

    final result = await widget.client.startSession(
      cwd: listing.path,
      trust: trust,
    );
    if (!mounted) return;
    if (!result.ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(result.error ?? 'could not start a session')),
      );
      return;
    }
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final listing = _listing;
    final atRoot = listing == null || _isAtRoot(listing);
    return Scaffold(
      appBar: AppBar(
        title: Text(listing?.path ?? 'Folders'),
        actions: [
          if (!atRoot)
            IconButton(
              icon: const Icon(Icons.arrow_upward),
              tooltip: 'Up',
              onPressed: _up,
            ),
        ],
      ),
      body: _body(listing),
      floatingActionButton: listing == null
          ? null
          : FloatingActionButton.extended(
              key: const Key('start-here'),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start session here'),
              onPressed: _startHere,
            ),
    );
  }

  Widget _body(DirListing? listing) {
    if (listing == null) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return Center(child: Text(_error ?? 'could not list the folder'));
    }
    return ListView(
      children: [
        if (_loading)
          const Padding(
            key: Key('listing-loading'),
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          ),
        if (_error != null)
          ListTile(
            leading: Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(_error!),
          ),
        for (final entry in listing.entries)
          ListTile(
            leading: const Icon(Icons.folder),
            title: Text(entry),
            onTap: () => _open(_join(listing.path, entry)),
          ),
        if (listing.truncated)
          const Padding(
            key: Key('listing-truncated'),
            padding: EdgeInsets.all(16),
            child: Text('Some entries are hidden.'),
          ),
      ],
    );
  }

  /// True when [listing] shows the browse root itself. Trailing slashes are
  /// ignored, so `/home/u/` and `/home/u` compare equal and Up is withheld.
  static bool _isAtRoot(DirListing listing) =>
      _stripTrailingSlash(listing.path) == _stripTrailingSlash(listing.root);

  /// [path] without one trailing slash; `/` and `''` are unchanged.
  static String _stripTrailingSlash(String path) =>
      path.length > 1 && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;

  /// A child path, tolerating a root of `/`.
  static String _join(String parent, String name) {
    final base = _stripTrailingSlash(parent);
    return base == '/' ? '/$name' : '$base/$name';
  }

  /// The parent path; `/` is its own parent.
  static String _parentOf(String path) {
    final trimmed = _stripTrailingSlash(path);
    final index = trimmed.lastIndexOf('/');
    if (index <= 0) return '/';
    return trimmed.substring(0, index);
  }
}
