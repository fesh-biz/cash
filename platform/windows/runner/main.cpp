#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

// ---------------------------------------------------------------------------
// Remember window size and position between launches.
// Stored in the registry: HKCU\Software\com.cash\cash\WindowPlacement.
// ---------------------------------------------------------------------------
namespace {

const wchar_t kPlacementKey[] = L"Software\\com.cash\\cash";
const wchar_t kPlacementValue[] = L"WindowPlacement";

WNDPROC g_original_proc = nullptr;
bool g_in_size_move = false;
bool g_pending_maximize = false;

void SavePlacement(HWND hwnd) {
  WINDOWPLACEMENT wp{};
  wp.length = static_cast<UINT>(sizeof(wp));
  if (!::GetWindowPlacement(hwnd, &wp)) {
    return;
  }
  ::RegSetKeyValueW(HKEY_CURRENT_USER, kPlacementKey, kPlacementValue,
                    REG_BINARY, &wp, static_cast<DWORD>(sizeof(wp)));
}

bool LoadPlacement(WINDOWPLACEMENT* wp) {
  DWORD size = static_cast<DWORD>(sizeof(*wp));
  if (::RegGetValueW(HKEY_CURRENT_USER, kPlacementKey, kPlacementValue,
                     RRF_RT_REG_BINARY, nullptr, wp,
                     &size) != ERROR_SUCCESS) {
    return false;
  }
  if (size != sizeof(*wp) || wp->length != sizeof(*wp)) {
    return false;
  }
  RECT r = wp->rcNormalPosition;
  if (r.right - r.left < 200 || r.bottom - r.top < 150) {
    return false;
  }
  // The monitor the window was on may have been disconnected: fall back to
  // the default position.
  if (::MonitorFromRect(&r, MONITOR_DEFAULTTONULL) == nullptr) {
    return false;
  }
  return true;
}

LRESULT CALLBACK PlacementWndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) {
  switch (message) {
    case WM_ENTERSIZEMOVE:
      g_in_size_move = true;
      break;
    case WM_EXITSIZEMOVE:
      g_in_size_move = false;
      SavePlacement(hwnd);
      break;
    case WM_SIZE:
      // Maximize/restore via the caption button or a double click.
      if (!g_in_size_move && ::IsWindowVisible(hwnd) &&
          (wparam == SIZE_MAXIMIZED || wparam == SIZE_RESTORED)) {
        SavePlacement(hwnd);
      }
      break;
    case WM_SHOWWINDOW:
      if (wparam != 0 && g_pending_maximize) {
        g_pending_maximize = false;
        ::PostMessageW(hwnd, WM_SYSCOMMAND, SC_MAXIMIZE, 0);
      }
      break;
    case WM_DESTROY:
      SavePlacement(hwnd);
      break;
  }
  return ::CallWindowProcW(g_original_proc, hwnd, message, wparam, lparam);
}

// Called while the window is still hidden (it is shown after the first frame).
void RestorePlacementAndTrack(HWND hwnd) {
  WINDOWPLACEMENT wp{};
  wp.length = static_cast<UINT>(sizeof(wp));
  if (LoadPlacement(&wp)) {
    g_pending_maximize =
        wp.showCmd == SW_SHOWMAXIMIZED ||
        (wp.showCmd == SW_SHOWMINIMIZED &&
         (wp.flags & WPF_RESTORETOMAXIMIZED) != 0);
    wp.showCmd = SW_HIDE;
    wp.flags = 0;
    // Applied twice: when the window moves to a monitor with a different DPI,
    // Windows rescales it after the first call; the second call restores the
    // exact saved size.
    ::SetWindowPlacement(hwnd, &wp);
    ::SetWindowPlacement(hwnd, &wp);
  }
  g_original_proc = reinterpret_cast<WNDPROC>(::SetWindowLongPtrW(
      hwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(PlacementWndProc)));
}

}  // namespace

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

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Cash", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  RestorePlacementAndTrack(window.GetHandle());

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
