import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/database/app_database.dart';
import '../core/services/app_clock.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshDate();
  }

  void _refreshDate() {
    _midnightTimer?.cancel();
    _now = ref.read(appClockProvider).now().toLocal();
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
                          : '${destination.label} is not available yet',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.index == 0
                          ? 'Habit tracking is not available yet. Your data will stay on this device.'
                          : 'This section is planned for a future milestone.',
                    ),
                  ],
                ),
              ),
            ),
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
