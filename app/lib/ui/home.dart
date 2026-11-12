// Главный экран: три колонки, как в Microsoft To Do; на телефоне колонки открываются по очереди.
import 'package:flutter/material.dart';

import '../core/sync.dart';
import 'common.dart';
import 'login.dart';
import 'sidebar.dart';
import 'task_editor.dart';
import 'task_list.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([app, app.repo, app.sync]),
      builder: (context, _) {
        final repo = app.repo;
        // вход: пока нет пользователя или токен устройства перестал действовать (в локальном режиме входа нет)
        final needLogin = !repo.loggedIn || (!repo.isLocal && (repo.token.isEmpty || (app.sync.state == SyncState.needLogin && !repo.detached)));
        if (needLogin) return const LoginScreen();
        return LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            if (w >= 1040) return const _Wide();
            if (w >= 680) return const _Medium();
            return const _Narrow();
          },
        );
      },
    );
  }
}

/// С фоновой картинкой экран прозрачный: картинку рисует TodoApp (main.dart).
Color? _scaffoldColor() => backgroundBytes(app.repo) == null ? null : Colors.transparent;

Widget? _detail() {
  final d = app.draft;
  if (d != null) return TaskEditor(key: ValueKey('draft:${d.id}'), task: d, isDraft: true);
  final t = app.repo.tasks[app.taskId];
  if (t != null && !t.deleted) return TaskEditor(key: ValueKey(t.id), task: t, isDraft: false);
  return null;
}

class _Wide extends StatelessWidget {
  const _Wide();
  @override
  Widget build(BuildContext context) => Live(builder: _build);

  Widget _build(BuildContext context) {
    final detail = _detail();
    return Scaffold(
      backgroundColor: _scaffoldColor(),
      body: SafeArea(
        child: Row(
          children: [
            const SizedBox(width: 290, child: Sidebar()),
            VerticalDivider(width: 1, color: borderOf(context)),
            const Expanded(child: TaskListPane()),
            if (detail != null) ...[VerticalDivider(width: 1, color: borderOf(context)), SizedBox(width: 380, child: detail)],
          ],
        ),
      ),
    );
  }
}

class _Medium extends StatelessWidget {
  const _Medium();
  @override
  Widget build(BuildContext context) => Live(builder: _build);

  Widget _build(BuildContext context) {
    final detail = _detail();
    return Scaffold(
      backgroundColor: _scaffoldColor(),
      body: SafeArea(
        child: Row(
          children: [
            const SizedBox(width: 270, child: Sidebar()),
            VerticalDivider(width: 1, color: borderOf(context)),
            Expanded(child: detail ?? const TaskListPane()),
          ],
        ),
      ),
    );
  }
}

/// Телефон: меню → список → карточка, «назад» возвращает на шаг.
class _Narrow extends StatefulWidget {
  const _Narrow();
  @override
  State<_Narrow> createState() => _NarrowState();
}

class _NarrowState extends State<_Narrow> {
  static bool showMenu = false;

  @override
  Widget build(BuildContext context) => Live(builder: _build);

  Widget _build(BuildContext context) {
    final detail = _detail();
    final Widget body;
    if (detail != null) {
      body = detail;
    } else if (showMenu) {
      body = Sidebar(onNavigate: () => setState(() => showMenu = false));
    } else {
      body = TaskListPane(onMenu: () => setState(() => showMenu = true));
    }
    return PopScope(
      canPop: detail == null && showMenu,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (detail != null) {
          app.closeTask();
        } else {
          setState(() => showMenu = true);
        }
      },
      child: Scaffold(
        backgroundColor: _scaffoldColor(),
        body: SafeArea(child: body),
      ),
    );
  }
}
