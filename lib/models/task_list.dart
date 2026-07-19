import '../core/json.dart';

/// A task container ("List" on the backend). The Inbox is the null-listId
/// pseudo-list and is not represented by a row.
class TaskList {
  TaskList({required this.id, required this.name, this.color, this.order});

  final String id;
  final String name;
  final String? color;
  final int? order;

  factory TaskList.fromJson(Map<String, dynamic> j) => TaskList(
        id: asString(j['id']),
        name: asString(j['name']),
        color: asStringOrNull(j['color']),
        order: j['order'] == null ? null : asInt(j['order']),
      );
}
