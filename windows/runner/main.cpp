#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"
#include "app_branding.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  ::SetLastError(0);
  HANDLE mutex = ::CreateMutexW(nullptr, FALSE, APP_MUTEX_NAME);
  if (mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing =
        ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", APP_WINDOW_TITLE);
    if (existing != nullptr) {
      if (::IsIconic(existing)) {
        ::ShowWindow(existing, SW_RESTORE);
      }
      ::SetForegroundWindow(existing);
      return EXIT_SUCCESS;
    }
    // 互斥量还在、窗口却找不到：上一个进程已经成了僵尸（崩溃或更新时留下的），
    // 这种情况不能再直接退出，否则用户看到的就是「点开闪一下就没了」。
  }

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
  Win32Window::Size size(1280, 720);
  Win32Window::Point origin(10, 10);
  HMONITOR primary = MonitorFromPoint({0, 0}, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  if (GetMonitorInfo(primary, &monitor)) {
    const double scale = FlutterDesktopGetDpiForMonitor(primary) / 96.0;
    const RECT& work = monitor.rcWork;
    const auto center = [scale](LONG start, LONG end, unsigned int extent) {
      return static_cast<unsigned int>((std::max)(
          start / scale, (start + end) / 2.0 / scale - extent / 2.0));
    };
    origin = Win32Window::Point(center(work.left, work.right, size.width),
                                center(work.top, work.bottom, size.height));
  }
  if (!window.Create(APP_WINDOW_TITLE, origin, size)) {
    // 别静默退出：闪退最难查的就是什么都不提示
    ::MessageBoxW(nullptr,
                  L"窗口创建失败，请重新安装影屿，或改用便携版（解压后运行）。",
                  APP_WINDOW_TITLE, MB_ICONERROR | MB_OK);
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
