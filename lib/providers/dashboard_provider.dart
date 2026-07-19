import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/analytics_repository.dart';
import '../models/dashboard.dart';
import 'providers.dart';

class DashboardController extends StateNotifier<AsyncValue<DashboardSummary>> {
  DashboardController(this._ref) : super(const AsyncValue.loading()) {
    load();
  }

  final Ref _ref;
  AnalyticsRepository get _repo => _ref.read(analyticsRepositoryProvider);

  Future<void> load() async {
    state = const AsyncValue.loading();
    await refresh();
  }

  Future<void> refresh() async {
    try {
      state = AsyncValue.data(await _repo.dashboard());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }
}

final dashboardControllerProvider =
    StateNotifierProvider<DashboardController, AsyncValue<DashboardSummary>>(
        (ref) => DashboardController(ref));
