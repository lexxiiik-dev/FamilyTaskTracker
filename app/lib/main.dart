import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app.dart';
import 'core/repo.dart';
import 'core/storage.dart';
import 'core/timezones.dart';
import 'core/sync.dart';
import 'platform/platform.dart';
import 'ui/common.dart';
import 'ui/home.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // в браузере правая кнопка открывает меню приложения (списки, поля ввода), а не меню браузера
  if (kIsWeb) await BrowserContextMenu.disableContextMenu();
  await initTimeZones();
  final platform = createPlatform();
  if (!await platform.preflight(args)) return; // уже запущен другой экземпляр
  final repo = Repo(openPlatformStorage());
  await repo.load();
  app = AppState(repo, SyncEngine(repo), platform);
  await app.start();
  runApp(const TodoApp());
}

class TodoApp extends StatelessWidget {
  const TodoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app.repo,
      builder: (context, _) {
        final mode = app.repo.setting<String>('theme', 'system');
        return MaterialApp(
          title: 'Задачи',
          // в браузере на телефоне в этот цвет красится адресная строка
          color: parseHex(app.repo.setting<String>('accent', ''), defaultAccent),
          debugShowCheckedModeBanner: false,
          builder: (context, child) => ScaledUi(
            scale: uiScalePercent(app.repo) / 100,
            child: Builder(
              builder: (context) {
                final bar = app.platform.titleBar();
                final bg = backgroundBytes(app.repo);
                final body = bar == null
                    ? child!
                    : Column(
                        children: [
                          bar,
                          Expanded(child: child!),
                        ],
                      );
                final base = Theme.of(context).scaffoldBackgroundColor;
                if (bg == null) return bar == null ? body : ColoredBox(color: base, child: body);
                // фоновая картинка лежит под всем окном и приглушается цветом темы
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(bg, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium),
                    ColoredBox(color: base.withValues(alpha: backgroundDim(app.repo))),
                    body,
                  ],
                );
              },
            ),
          ),
          theme: buildTheme(app.repo, Brightness.light),
          darkTheme: buildTheme(app.repo, Brightness.dark),
          themeMode: mode == 'dark' ? ThemeMode.dark : (mode == 'light' ? ThemeMode.light : ThemeMode.system),
          locale: const Locale('ru'),
          supportedLocales: const [Locale('ru')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const HomeScreen(),
        );
      },
    );
  }
}
