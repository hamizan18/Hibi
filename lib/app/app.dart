import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/database/app_database.dart';
import '../core/services/app_clock.dart';
import '../features/finance/presentation/finance_screen.dart';
import '../features/growth/presentation/growth_screen.dart';
import '../features/habits/domain/habit_schedule.dart';
import '../features/habits/presentation/habit_builder_screen.dart';
import '../features/habits/presentation/history_analytics_screen.dart';
import '../features/habits/presentation/today_habit_roster.dart';
import 'theme/hibi_theme.dart';

const _destinations = [
  (label: 'Today', path: '/', icon: Icons.today_outlined),
  (label: 'History', path: '/history', icon: Icons.calendar_month_outlined),
  (
    label: 'Finance',
    path: '/finance',
    icon: Icons.account_balance_wallet_outlined,
  ),
  (label: 'Growth', path: '/growth', icon: Icons.insights_outlined),
  (label: 'More', path: '/more', icon: Icons.more_horiz),
];

final _routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    routes: [
      for (var i = 0; i < _destinations.length; i++)
        GoRoute(
          path: _destinations[i].path,
          builder: (context, state) => _FoundationScreen(index: i),
        ),
      GoRoute(
        path: '/habit-builder',
        builder: (context, state) => const HabitBuilderScreen(),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
final databaseInitializationProvider = FutureProvider<void>((ref) async {
  await ref.watch(databaseProvider).getSetting('theme');
});

class HibiApp extends ConsumerWidget {
  const HibiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initialization = ref.watch(databaseInitializationProvider);
    return initialization.when(
      data: (_) => MaterialApp.router(
        title: 'Hibi',
        debugShowCheckedModeBanner: false,
        theme: createHibiTheme(),
        routerConfig: ref.watch(_routerProvider),
      ),
      loading: () => MaterialApp(
        theme: createHibiTheme(),
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
      error: (error, stack) => MaterialApp(
        theme: createHibiTheme(),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Unable to open local storage: $error'),
            ),
          ),
        ),
      ),
    );
  }
}

class _FoundationScreen extends ConsumerStatefulWidget {
  const _FoundationScreen({required this.index});
  final int index;

  @override
  ConsumerState<_FoundationScreen> createState() => _FoundationScreenState();
}

class _FoundationScreenState extends ConsumerState<_FoundationScreen>
    with WidgetsBindingObserver {
  Timer? _midnightTimer;
  late DateTime _now;
  int _rosterRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshDate();
  }

  void _refreshDate() {
    _midnightTimer?.cancel();
    _now = ref.read(appClockProvider).now().toLocal();
    _rosterRevision++;
    final nextDay = DateTime(_now.year, _now.month, _now.day + 1);
    _midnightTimer = Timer(nextDay.difference(_now), () {
      if (mounted) setState(_refreshDate);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) setState(_refreshDate);
  }

  @override
  void dispose() {
    _midnightTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final destination = _destinations[widget.index];
    return Scaffold(
      appBar: AppBar(title: Text(destination.label)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (widget.index == 0) ...[
              Text(
                japaneseDate(_now),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'Small steps, every day.',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 24),
            ],
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.index == 0
                          ? 'Welcome to Hibi'
                          : widget.index == 1
                          ? 'History & Analytics'
                          : widget.index == 2
                          ? 'Finance (IDR)'
                          : widget.index == 3
                          ? 'Journal, Goals & Focus'
                          : 'More',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.index == 0
                          ? 'Your habits stay on this device.'
                          : widget.index == 1
                          ? 'Deterministic calendar, weighted score, recording coverage, heatmaps, streaks and reports.'
                          : widget.index == 2
                          ? 'Integer IDR wallets, transactions, atomic transfers, expense budgets and audited reports.'
                          : widget.index == 3
                          ? 'Optional journal and mood, goals with milestones, and restart-safe focus sessions.'
                          : 'Create a habit below. Other features are not available yet.',
                    ),
                  ],
                ),
              ),
            ),
            if (widget.index == 0) ...[
              const SizedBox(height: 16),
              TodayHabitRoster(
                key: ValueKey(_rosterRevision),
                date: LocalDate(_now.year, _now.month, _now.day),
              ),
            ],
            if (widget.index == 1) ...[
              const SizedBox(height: 16),
              HistoryAnalyticsView(
                key: ValueKey(_rosterRevision),
                asOfDate: LocalDate(_now.year, _now.month, _now.day),
              ),
            ],
            if (widget.index == 2) ...[
              const SizedBox(height: 16),
              FinanceView(
                key: ValueKey(_rosterRevision),
                asOfDate: LocalDate(_now.year, _now.month, _now.day),
              ),
            ],
            if (widget.index == 3) ...[
              const SizedBox(height: 16),
              GrowthView(
                key: ValueKey(_rosterRevision),
                asOfDate: LocalDate(_now.year, _now.month, _now.day),
              ),
            ],
            if (widget.index == 0 || widget.index == 4) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () async {
                  await context.push('/habit-builder');
                  if (mounted) setState(() => _rosterRevision++);
                },
                icon: const Icon(Icons.add),
                label: const Text('Create habit'),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: widget.index,
        onDestinationSelected: (index) => context.go(_destinations[index].path),
        destinations: [
          for (final item in _destinations)
            NavigationDestination(icon: Icon(item.icon), label: item.label),
        ],
      ),
    );
  }
}
