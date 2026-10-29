import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api.dart';
import 'store.dart';
import 'theme.dart';
import 'updater.dart';
import 'screens/home_screen.dart';
import 'screens/plans_screen.dart';
import 'screens/activate_screen.dart';
import 'screens/orders_screen.dart';
import 'screens/account_screen.dart';
import 'screens/cart_screen.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState(),
      child: const EsimApp(),
    ),
  );
}

class EsimApp extends StatelessWidget {
  const EsimApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Onlylink Travel eSIM',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const _Gate(),
    );
  }
}

class _Gate extends StatefulWidget {
  const _Gate();
  @override
  State<_Gate> createState() => _GateState();
}

class _GateState extends State<_Gate> {
  @override
  void initState() {
    super.initState();
    // Check for an app update once, shortly after first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) AppUpdater.maybePrompt(context);
    });
  }

  /// Watchdog: if state initialisation has not completed within a few seconds,
  /// force the UI forward instead of sitting on the splash forever.
  ///
  /// The app previously had no escape hatch, so any startup bug (a blocked
  /// plugin call, a slow storage read) presented as a permanent splash with no
  /// way to diagnose it from the phone. Entering the shell is always safer than
  /// hanging: the screens fetch their own data and surface errors themselves.
  void _startWatchdog() {
    Future.delayed(const Duration(seconds: 6), () {
      if (!mounted) return;
      final app = context.read<AppState>();
      if (!app.ready) app.forceReady('startup timed out');
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_watchdogStarted) {
      _watchdogStarted = true;
      _startWatchdog();
    }
  }

  bool _watchdogStarted = false;

  @override
  Widget build(BuildContext context) {
    final ready = context.watch<AppState>().ready;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      child: ready ? const Shell() : const SplashScreen(),
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.heroBlue),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 88, height: 88,
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(24)),
                child: const Icon(Icons.sim_card, color: Colors.white, size: 46),
              ),
              const SizedBox(height: 20),
              const Text('Onlylink', style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
              const SizedBox(height: 6),
              Text('Travel eSIM', style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
              const SizedBox(height: 28),
              // Build diagnostics, visible even if startup stalls. This is the
              // fastest way to tell which build is installed and which backend
              // it is pointed at -- both have caused confusion before.
              Text(
                'v${AppInfo.version} (${AppInfo.build})',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(
                ApiConfig.baseUrl,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 10.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;

  void _go(int tab) => setState(() => _index = tab);

  @override
  Widget build(BuildContext context) {
    final t = context.watch<AppState>().t;
    final pages = [
      HomeScreen(onGoTab: _go),
      PlansScreen(onGoTab: _go),
      const ActivateScreen(),
      OrdersScreen(onGoTab: _go),
      AccountScreen(onGoTab: _go),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: [
          BottomNavigationBarItem(icon: const Icon(Icons.home_outlined), activeIcon: const Icon(Icons.home), label: t.navHome),
          BottomNavigationBarItem(icon: const Icon(Icons.grid_view_outlined), activeIcon: const Icon(Icons.grid_view), label: t.navPlans),
          BottomNavigationBarItem(icon: const Icon(Icons.qr_code_scanner_outlined), activeIcon: const Icon(Icons.qr_code_scanner), label: t.navActivate),
          BottomNavigationBarItem(icon: const Icon(Icons.receipt_long_outlined), activeIcon: const Icon(Icons.receipt_long), label: t.navOrders),
          BottomNavigationBarItem(icon: const Icon(Icons.person_outline), activeIcon: const Icon(Icons.person), label: t.navMe),
        ],
      ),
      floatingActionButton: context.watch<AppState>().cartCount > 0 && _index != 2
          ? FloatingActionButton.extended(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CartScreen())),
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.shopping_cart_outlined),
              label: Text('${t.cart} (${context.watch<AppState>().cartCount})'),
            )
          : null,
    );
  }
}

void showSnack(BuildContext context, String msg, {bool error = false}) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(msg),
      backgroundColor: error ? AppColors.danger : AppColors.success,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ),
  );
}
