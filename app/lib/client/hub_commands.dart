// ignore_for_file: prefer_initializing_formals
// The store/pending/notify fields are private, and a private *named* parameter
// is illegal in Dart, so the initializer list is the only way to bind them (the
// lint's suggested fix does not compile).

/// Stateless request builders: the allowlisted commands, `list-dirs`, the
/// app-started session requests, and the command cache refresh.
///
/// Extracted from the hub client: each method builds a wire frame and hands it
/// to [PendingRegistry], which owns the correlation and the bounded waits. The
/// state it reads is the store's; the notification it raises is the
/// coalescer's. No [HubClient] back-reference.
library;

import 'dart:async';

import '../protocol/protocol.dart';
import 'hub_models.dart';
import 'notify_coalescer.dart';
import 'pending_registry.dart';
import 'session_state.dart';

/// Builds and sends the hub's request frames, correlating each through
/// [PendingRegistry].
class CommandSender {
  CommandSender({
    required SessionStateStore store,
    required PendingRegistry pending,
    required NotifyCoalescer notify,
  }) : _store = store,
       _pending = pending,
       _notify = notify;

  final SessionStateStore _store;
  final PendingRegistry _pending;
  final NotifyCoalescer _notify;

  Future<CommandResult> sendCommand(
    String sessionId,
    String name, {
    Map<String, Object?>? args,
    String? id,
  }) {
    return _pending.command(sessionId: sessionId, id: id, build: (commandId) {
      final message = <String, Object?>{
        'protocolVersion': protocolVersion,
        'type': 'command',
        'id': commandId,
        'sessionId': sessionId,
        'name': name,
      };
      if (args != null) message['args'] = args;
      return message;
    });
  }

  Future<CommandResult> listCommands(String sessionId, {String? id}) {
    return _pending.command(
      sessionId: sessionId,
      id: id,
      build: (commandId) => <String, Object?>{
        'protocolVersion': protocolVersion,
        'type': 'command',
        'id': commandId,
        'sessionId': sessionId,
        'name': 'listCommands',
      },
    );
  }

  Future<CommandResult> listModels(String sessionId, {String? id}) {
    return _pending.command(
      sessionId: sessionId,
      id: id,
      build: (commandId) => <String, Object?>{
        'protocolVersion': protocolVersion,
        'type': 'command',
        'id': commandId,
        'sessionId': sessionId,
        'name': 'listModels',
      },
    );
  }

  Future<CommandResult> listTree(String sessionId, {String? id}) {
    return _pending.command(
      sessionId: sessionId,
      id: id,
      build: (commandId) => <String, Object?>{
        'protocolVersion': protocolVersion,
        'type': 'command',
        'id': commandId,
        'sessionId': sessionId,
        'name': 'listTree',
      },
    );
  }

  Future<CommandResult> sessionNew(String sessionId, {String? id}) {
    return _pending.command(
      sessionId: sessionId,
      id: id,
      followsReplacement: true,
      build: (commandId) {
        return <String, Object?>{
          'protocolVersion': protocolVersion,
          'type': 'command',
          'id': commandId,
          'sessionId': sessionId,
          'name': 'sessionNew',
        };
      },
    );
  }

  Future<CommandResult> sessionFork(
    String sessionId,
    String entryId, {
    String? id,
  }) {
    return _pending.command(
      sessionId: sessionId,
      id: id,
      followsReplacement: true,
      build: (commandId) {
        return <String, Object?>{
          'protocolVersion': protocolVersion,
          'type': 'command',
          'id': commandId,
          'sessionId': sessionId,
          'name': 'sessionFork',
          'args': {'entryId': entryId},
        };
      },
    );
  }

  Future<CommandResult> sessionTree(
    String sessionId,
    String entryId, {
    String? id,
  }) {
    return _pending.command(
      sessionId: sessionId,
      id: id,
      build: (commandId) {
        return <String, Object?>{
          'protocolVersion': protocolVersion,
          'type': 'command',
          'id': commandId,
          'sessionId': sessionId,
          'name': 'sessionTree',
          'args': {'entryId': entryId},
        };
      },
    );
  }

  Future<void> loadCommands(String sessionId) async {
    final result = await listCommands(sessionId);
    if (!result.ok || result.commands == null) return;
    if (!_store.state.transcripts.containsKey(sessionId)) return;
    _store.update(
      (state) => state.copyWith(
        commands: {...state.commands, sessionId: result.commands!},
      ),
    );
    _notify.schedule();
  }

  Future<CommandResult> startSession({String? id, String? cwd, bool? trust}) {
    if ((cwd != null || trust != null) &&
        !_store.state.capabilities.contains(capabilityProjectSession)) {
      return Future.value(
        const CommandResult(
          ok: false,
          error: 'this hub cannot start a session in a chosen folder',
        ),
      );
    }
    return _pending.command(
      sessionId: '',
      id: id,
      build: (commandId) {
        final message = <String, Object?>{
          'protocolVersion': protocolVersion,
          'type': 'start-session',
          'id': commandId,
        };
        if (cwd != null) message['cwd'] = cwd;
        if (trust != null && cwd != null) message['trust'] = trust;
        return message;
      },
    );
  }

  Future<DirListingResult> listDirs({String? path, String? id}) {
    if (!_store.state.capabilities.contains(capabilityListDirs)) {
      return Future.value(
        const DirListingResult(ok: false, error: 'this hub cannot browse folders'),
      );
    }
    return _pending.listing(id: id, build: (listingId) {
      final message = <String, Object?>{
        'protocolVersion': protocolVersion,
        'type': 'list-dirs',
        'id': listingId,
      };
      if (path != null && path.isNotEmpty) message['path'] = path;
      return message;
    });
  }

  Future<CommandResult> killSession(String sessionId, {String? id}) {
    return _pending.command(
      sessionId: '',
      id: id,
      build: (commandId) => <String, Object?>{
        'protocolVersion': protocolVersion,
        'type': 'kill-session',
        'id': commandId,
        'sessionId': sessionId,
      },
    );
  }
}
