import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'src/state.dart';
import 'src/loading.dart';
import 'src/appearance.dart';
import 'src/map_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: SporraApp()));
}

final router = GoRouter(
  routes: [GoRoute(path: '/', builder: (_, _) => const RootScreen())],
);

class SporraApp extends StatelessWidget {
  const SporraApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Sporra',
    debugShowCheckedModeBanner: false,
    theme: webTheme(menuRadius: menuCornerRadius(context)),
    routerConfig: router,
  );
}

class RootScreen extends ConsumerStatefulWidget {
  const RootScreen({super.key});
  @override
  ConsumerState<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends ConsumerState<RootScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(appProvider).initialize());
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    if (!app.ready) {
      return const Scaffold(
        body: Center(child: LoadingIndicator(label: 'Loading your map…')),
      );
    }
    return app.user == null ? const LoginScreen() : const MapScreen();
  }
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final server = TextEditingController();
  final username = TextEditingController();
  final password = TextEditingController();
  bool register = false;
  @override
  void initState() {
    super.initState();
    server.text = ref.read(appProvider).api.server;
  }

  @override
  void dispose() {
    server.dispose();
    username.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.blur_on, size: 72, color: Colors.white),
                  const SizedBox(height: 20),
                  Text(
                    'Your world,\nremembered.',
                    style: Theme.of(context).textTheme.displaySmall,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Connect to your Sporra server to see the places you have been.',
                    style: TextStyle(color: Colors.white60),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: server,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Server address',
                      hintText: 'https://sporra.example.com',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: username,
                    autofillHints: const [AutofillHints.username],
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Username'),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: password,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: const InputDecoration(labelText: 'Password'),
                    onSubmitted: (_) => submit(app),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: app.busy ? null : () => submit(app),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: app.busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: LoadingIndicator(showLabel: false),
                            )
                          : Text(register ? 'Create account' : 'Sign in'),
                    ),
                  ),
                  TextButton(
                    onPressed: app.busy
                        ? null
                        : () => setState(() => register = !register),
                    child: Text(
                      register
                          ? 'Already have an account? Sign in'
                          : 'Create an account',
                    ),
                  ),
                  if (app.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        app.error!,
                        style: const TextStyle(color: Colors.orangeAccent),
                      ),
                    ),
                  const SizedBox(height: 28),
                  const Text(
                    'Sporra Preview · native map for iOS',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void submit(AppState app) =>
      app.login(server.text, username.text, password.text, register: register);
}
