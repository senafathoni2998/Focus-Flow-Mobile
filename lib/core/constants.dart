import 'package:flutter/material.dart';

/// Mirrors the backend's task/habit/goal value sets and the app's semantic color
/// palette (primary|success|warning|danger), so the mobile UI stays in lockstep
/// with `src/lib/taskConstants.ts` and the Tailwind palette keys.

// ---- Task status / priority ---------------------------------------------------

const List<String> kTaskStatuses = ['todo', 'in-progress', 'completed', 'wont-do'];
const List<String> kTaskPriorities = ['none', 'low', 'medium', 'high'];
const List<String> kTerminalStatuses = ['completed', 'wont-do'];

const Map<String, String> kStatusLabels = {
  'todo': 'To Do',
  'in-progress': 'In Progress',
  'completed': 'Completed',
  'wont-do': "Won't Do",
};

const Map<String, String> kPriorityLabels = {
  'none': 'None',
  'low': 'Low',
  'medium': 'Medium',
  'high': 'High',
};

bool isTerminalStatus(String? status) => status != null && kTerminalStatuses.contains(status);

int priorityRankOf(String? p) {
  switch (p) {
    case 'high':
      return 3;
    case 'medium':
      return 2;
    case 'low':
      return 1;
    case 'none':
      return 0;
    default:
      return 2;
  }
}

Color priorityColor(String? p) {
  switch (p) {
    case 'high':
      return const Color(0xFFEF4444); // red-500
    case 'medium':
      return const Color(0xFFF59E0B); // amber-500
    case 'low':
      return const Color(0xFF3B82F6); // blue-500
    default:
      return const Color(0xFF9CA3AF); // gray-400
  }
}

// ---- Recurrence ---------------------------------------------------------------

const List<String> kRecurrenceFreqs = ['daily', 'weekly', 'monthly', 'yearly'];
const Map<String, String> kRecurrenceLabels = {
  'daily': 'Daily',
  'weekly': 'Weekly',
  'monthly': 'Monthly',
  'yearly': 'Yearly',
};

// ---- Semantic palette (primary|success|warning|danger) ------------------------

const List<String> kSemanticColors = ['primary', 'success', 'warning', 'danger'];

Color semanticColor(String? key) {
  switch (key) {
    case 'success':
      return const Color(0xFF10B981); // emerald-500
    case 'warning':
      return const Color(0xFFF59E0B); // amber-500
    case 'danger':
      return const Color(0xFFEF4444); // red-500
    case 'primary':
    default:
      return const Color(0xFF6366F1); // indigo-500
  }
}

// ---- Habits / Goals -----------------------------------------------------------

const List<String> kHabitFrequencyTypes = ['daily', 'weekly'];
const List<String> kHabitGoalTypes = ['achieve', 'amount'];
const List<String> kGoalProgressTypes = ['manual', 'numeric', 'tasks'];
const List<String> kGoalStatuses = ['active', 'achieved', 'archived'];

const List<String> kWeekdayLabels = ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'];

// A small starter palette of emoji for habit/goal icon pickers.
const List<String> kIconChoices = [
  '✅', '📚', '🏃', '💧', '🧘', '💪', '🎯', '🍎', '😴', '✍️', '🎨', '🎸',
  '💰', '🧹', '📝', '☕', '🌱', '🔥', '⭐', '🧠', '💻', '🚴', '🏋️', '🥗',
];
