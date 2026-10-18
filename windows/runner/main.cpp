#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // The player's WebView2 (webview_win_floating) takes its browser options
  // from here: play with sound without a click on the page (the click lands
  // on the app). Anything already set (a debug port) is kept.
  {
    wchar_t existing[2048] = L"";
    ::GetEnvironmentVariableW(L"WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", existing, 2048);
    std::wstring args = existing;
    if (!args.empty()) args += L" ";
    args += L"--autoplay-policy=no-user-gesture-required";
    // A debug port, only on a PC that asks for one: a file named debug-port
    // in the app's settings folder, holding the port number. WebView2 listens
    // on that PC alone (127.0.0.1), and lets the player be looked at live,
    // without relaunching the app and losing what it has in memory.
    wchar_t appdata[MAX_PATH] = L"";
    if (args.find(L"--remote-debugging-port") == std::wstring::npos &&
        ::GetEnvironmentVariableW(L"APPDATA", appdata, MAX_PATH) > 0) {
      std::wstring path =
          std::wstring(appdata) + L"\\com.micahmo\\sports\\debug-port";
      HANDLE f = ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                               nullptr, OPEN_EXISTING, 0, nullptr);
      if (f != INVALID_HANDLE_VALUE) {
        char buf[16] = {};
        DWORD read = 0;
        ::ReadFile(f, buf, sizeof(buf) - 1, &read, nullptr);
        ::CloseHandle(f);
        const int port = atoi(buf);
        if (port > 1024 && port < 65536) {
          args += L" --remote-debugging-port=" + std::to_wstring(port);
        }
      }
    }
    ::SetEnvironmentVariableW(L"WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", args.c_str());
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"sports", origin, size)) {
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
