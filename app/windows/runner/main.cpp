#include <winsock2.h>
#include <ws2tcpip.h>

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdlib>
#include <string>

#include "flutter_window.h"
#include "utils.h"

// The app is already running (usually hidden in the tray): pass it the link from the
// command line and quit before the Flutter engine starts, so the window shows up at once
// and no extra process is left behind. The running instance listens in Dart
// (preflight in lib/platform/platform_io.dart): TCP 127.0.0.1, payload = link text.
static bool HandOverToRunningInstance() {
  const bool test = ::GetEnvironmentVariableW(L"TODO_DATA_DIR", nullptr, 0) > 0;
  const unsigned short port = test ? 47612 : 47611;
  // The mutex lives as long as the first instance does; without it we skip the connect.
  HANDLE mutex = ::CreateMutexW(nullptr, FALSE, test ? L"Local\\todo-app-test" : L"Local\\todo-app");
  if (mutex == nullptr) return false;
  if (::GetLastError() != ERROR_ALREADY_EXISTS) return false;  // first instance: keep the handle open until exit
  ::CloseHandle(mutex);

  std::string link;
  for (const auto& a : GetCommandLineArguments()) {
    if (a.rfind("todo-app:", 0) == 0) link = a;
  }
  WSADATA wsa;
  if (::WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return false;
  bool ok = false;
  SOCKET s = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (s != INVALID_SOCKET) {
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = ::htons(port);
    ::inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    // Let the running instance bring its window to the foreground.
    ::AllowSetForegroundWindow(ASFW_ANY);
    if (::connect(s, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0) {
      if (!link.empty()) ::send(s, link.data(), static_cast<int>(link.size()), 0);
      ::shutdown(s, SD_SEND);
      ok = true;
    }
    ::closesocket(s);
  }
  ::WSACleanup();
  return ok;  // failed: start normally, the Dart preflight sorts it out
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (HandOverToRunningInstance()) return EXIT_SUCCESS;

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"\x0417\x0430\x0434\x0430\x0447\x0438", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
