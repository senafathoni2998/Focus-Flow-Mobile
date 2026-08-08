import '../../models/task_list.dart';
import 'queue_op.dart';

/// The lists overlay — the same shape as the task one, and for the same reason:
/// server truth lives UNDERNEATH, so a refresh landing mid-write cannot erase a
/// list the user just created offline.
///
/// Only creates and deletes are folded. PATCH /lists/:id is deliberately not
/// queued (DECISIONS.md F7): `ListsController.update` has no caller anywhere in
/// the app, so queueing it would be building an offline path for something the
/// UI cannot do online either.

/// Build the list JSON the server would have returned for a create body.
///
/// `order` is left null on purpose. It is assigned server-side and the drawer
/// does not sort on it, so inventing a number would put a value on screen that
/// the real response silently contradicts.
Map<String, dynamic> listJsonFromCreateBody(
  String localId,
  Map<String, dynamic> body,
) {
  return <String, dynamic>{
    'id': localId,
    'name': body['name'] is String ? body['name'] as String : '',
    'color': body['color'],
    'order': null,
  };
}

/// Fold pending list ops over the last `GET /lists`.
List<TaskList> applyListQueue(
  List<TaskList> server,
  List<QueuedOp> ops,
  Map<String, String> idMap,
) {
  final List<QueuedOp> ordered = ops
      .where((QueuedOp o) => o.entity == OpEntity.list)
      .toList()
    ..sort((QueuedOp a, QueuedOp b) => a.seq.compareTo(b.seq));
  if (ordered.isEmpty) return server;

  final List<Map<String, dynamic>> rows =
      server.map((TaskList l) => l.toJson()).toList();

  int indexOf(String id) {
    final String mapped = idMap[id] ?? id;
    for (int i = 0; i < rows.length; i++) {
      final Object? rowId = rows[i]['id'];
      if (rowId == id || rowId == mapped) return i;
    }
    return -1;
  }

  for (final QueuedOp op in ordered) {
    switch (op.kind) {
      case OpKind.createList:
        {
          final String? localId = op.assigns;
          final Map<String, dynamic>? body = op.body;
          if (localId == null || body == null) break;
          // Once the create lands and a refresh brings back the real row, the
          // shadow must not be added again or the drawer shows it twice.
          if (indexOf(localId) >= 0) break;
          rows.add(listJsonFromCreateBody(localId, body));
        }

      case OpKind.deleteList:
        {
          // A FAILED delete means the list is still on the server, so hiding it
          // would be the app asserting something untrue. See the note in
          // task_overlay.dart's fold.
          if (op.reason != null) break;
          final int i = indexOf(op.target);
          if (i < 0) break;
          rows.removeAt(i);
        }

      case OpKind.createTask:
      case OpKind.updateTask:
      case OpKind.completeTask:
      case OpKind.deleteTask:
        // Filtered out above; enumerated so a new entity cannot be added
        // without the compiler asking what this overlay should do about it.
        break;
    }
  }

  return rows.map(TaskList.fromJson).toList();
}
