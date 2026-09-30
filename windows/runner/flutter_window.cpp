#include "flutter_window.h"

#include <optional>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "sports/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setFullScreen") {
          const bool* on = std::get_if<bool>(call.arguments());
          SetFullScreen(on != nullptr && *on);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

// Fullscreen in one step, the way Plezy does it: take the frame off and cover
// the monitor the window is mostly on, leaving it maximized or not underneath.
// window_manager's setFullScreen leaves the title bar and taskbar showing on a
// maximized window, so the player had to un-maximize first and the window
// visibly resized twice; it can also land on the wrong monitor.
void FlutterWindow::SetFullScreen(bool fullscreen) {
  HWND hwnd = GetHandle();
  if (!hwnd || fullscreen == fullscreen_) return;

  if (fullscreen) {
    // The monitor under the window's centre: MonitorFromWindow can pick the
    // neighbour for a maximized window that overhangs it slightly.
    RECT wr{};
    ::GetWindowRect(hwnd, &wr);
    POINT centre{(wr.left + wr.right) / 2, (wr.top + wr.bottom) / 2};
    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    if (!::GetMonitorInfoW(
            ::MonitorFromPoint(centre, MONITOR_DEFAULTTONEAREST), &mi)) {
      return;
    }

    // The placement carries whether it was maximized.
    placement_before_fullscreen_ = {};
    placement_before_fullscreen_.length = sizeof(WINDOWPLACEMENT);
    ::GetWindowPlacement(hwnd, &placement_before_fullscreen_);
    style_before_fullscreen_ = ::GetWindowLongPtr(hwnd, GWL_STYLE);
    ex_style_before_fullscreen_ = ::GetWindowLongPtr(hwnd, GWL_EXSTYLE);

    // Without the frame, one SetWindowPos gives exactly the monitor's rect, so
    // Flutter lays out once, at the final size.
    ::SetWindowLongPtr(hwnd, GWL_STYLE,
                       style_before_fullscreen_ & ~WS_OVERLAPPEDWINDOW);
    ::SetWindowLongPtr(hwnd, GWL_EXSTYLE,
                       ex_style_before_fullscreen_ &
                           ~(WS_EX_DLGMODALFRAME | WS_EX_WINDOWEDGE |
                             WS_EX_CLIENTEDGE | WS_EX_STATICEDGE));
    const RECT& r = mi.rcMonitor;
    ::SetWindowPos(hwnd, HWND_TOP, r.left, r.top, r.right - r.left,
                   r.bottom - r.top,
                   SWP_FRAMECHANGED | SWP_NOZORDER | SWP_NOACTIVATE);
    fullscreen_ = true;
  } else {
    ::SetWindowLongPtr(hwnd, GWL_STYLE, style_before_fullscreen_);
    ::SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex_style_before_fullscreen_);
    WINDOWPLACEMENT wp = placement_before_fullscreen_;
    if (wp.showCmd == SW_SHOWMINIMIZED) wp.showCmd = SW_SHOWNORMAL;
    ::SetWindowPlacement(hwnd, &wp);
    // Repaint the frame that just came back.
    ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                       SWP_FRAMECHANGED);
    fullscreen_ = false;
  }
}
