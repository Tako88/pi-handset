/// The narrow hub client contract the UI depends on.
///
/// The UI screens need the client's state, the streams they listen to, and the
/// commands they issue — not the concrete `HubClient` class. This interface is
/// that seam, so a screen can be typed against it and tested without the whole
/// state layer.
///
/// Pure Dart: no Flutter import, so it tests without a widget binding. The value
/// types are re-exported here so an importer of this file resolves them without
/// also importing `hub_models.dart`.
library;

import 'dart:async';

import 'endpoint_store.dart';
import 'hub_models.dart';
export 'hub_models.dart';

/// Everything the UI calls on the hub client.
abstract interface class HubClientView {
  // state as a value + the streams the UI listens to
  HubClientState get state;
  bool get lastErrorFromConnection;
  Stream<HubClientState> get changes;
  Stream<AgentSettledEvent> get settles;
  Stream<LeafEvent> get leafEvents;

  // the commands the UI issues
  Future<void> startCandidates(List<HubEndpoint> candidates, {String? ticket, HubEndpoint? prefer});
  void subscribe(String sessionId);
  void unsubscribe(String sessionId);
  void loadOlder(String sessionId);
  Future<CommandResult> sendCommand(String sessionId, String name, {Map<String, Object?>? args, String? id});
  Future<CommandResult> listModels(String sessionId, {String? id});
  Future<CommandResult> listTree(String sessionId, {String? id});
  Future<CommandResult> sessionNew(String sessionId, {String? id});
  Future<CommandResult> sessionFork(String sessionId, String entryId, {String? id});
  Future<CommandResult> sessionTree(String sessionId, String entryId, {String? id});
  Future<void> loadCommands(String sessionId);
  Future<CommandResult> startSession({String? id, String? cwd, bool? trust});
  Future<DirListingResult> listDirs({String? path, String? id});
  Future<CommandResult> killSession(String sessionId, {String? id});
}
