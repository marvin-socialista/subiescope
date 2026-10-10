import CWebView2
import Foundation
import WinSDK

/// The app's one window, and the message loop the whole app runs on.
@MainActor
final class AppWindow {
    static var shared: AppWindow?

    let handle: HWND
    let webView = WebView()
    /// The window is about to close: the last chance to save things.
    var onClose: (() -> Void)?

    private static let className = Array("SubieScopeWindow".utf16) + [0]
    private static let drainTimer: UINT_PTR = 1
    private static let saveTimer: UINT_PTR = 2
    private var draining = false

    /// `size` is in points: the window is made larger on a screen that is scaled up.
    init?(title: String, size: (width: Int32, height: Int32), activate: Bool) {
        host_use_screen_scaling()
        let instance = GetModuleHandleW(nil)
        var windowClass = WNDCLASSEXW()
        windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        windowClass.lpfnWndProc = { window, message, wParam, lParam in
            let handled: LRESULT? = MainActor.assumeIsolated {
                AppWindow.shared?.handle(message: message, wParam: wParam, lParam: lParam)
            }
            return handled ?? DefWindowProcW(window, message, wParam, lParam)
        }
        windowClass.hInstance = instance
        windowClass.hCursor = host_arrow_cursor()?.assumingMemoryBound(to: HICON__.self)
        windowClass.hIcon = host_app_icon(0)?.assumingMemoryBound(to: HICON__.self)
        windowClass.hIconSm = host_app_icon(1)?.assumingMemoryBound(to: HICON__.self)
        // The colour of the page's own background, so the window does not flash white while the page loads.
        let dark = host_dark_mode() != 0
        windowClass.hbrBackground = CreateSolidBrush(dark ? 0x001E_1E1E : 0x00F5_F4F4)
        let scale = Int32(GetDpiForSystem())
        let created: HWND? = Self.className.withUnsafeBufferPointer { name in
            windowClass.lpszClassName = name.baseAddress
            guard RegisterClassExW(&windowClass) != 0 else { return nil }
            return title.withCString(encodedAs: UTF16.self) { title in
                CreateWindowExW(0, name.baseAddress, title, DWORD(WS_OVERLAPPEDWINDOW),
                                Int32(bitPattern: 0x8000_0000), Int32(bitPattern: 0x8000_0000),
                                size.width * scale / 96, size.height * scale / 96, nil, nil, instance, nil)
            }
        }
        guard let created else { return nil }
        handle = created
        host_set_dark_title_bar(UnsafeMutableRawPointer(created), dark ? 1 : 0)
        Desktop.window = created
        AppWindow.shared = self
        // A safety net: while Windows runs a loop of its own (dragging the window, a menu), this timer
        // keeps the main actor's work going.
        SetTimer(created, Self.drainTimer, 50, nil)
        // Foundation on Windows keeps changed settings in memory until it is told to write them. Every
        // few seconds is often enough to lose nothing that matters when the PC is switched off.
        SetTimer(created, Self.saveTimer, 5000, nil)
        let maximized = restorePlacement()
        ShowWindow(created, activate ? (maximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL) : SW_SHOWNOACTIVATE)
        UpdateWindow(created)
    }

    // MARK: Where the window was

    private static let placementKey = "windowPlacement"

    /// Puts the window back where it was closed, when that place is still on a screen.
    /// Returns whether it was maximized then.
    private func restorePlacement() -> Bool {
        let saved = (UserDefaults.standard.string(forKey: Self.placementKey) ?? "").split(separator: ",").compactMap { Int32($0) }
        guard saved.count == 5 else { return false }
        var frame = RECT(left: saved[0], top: saved[1], right: saved[2], bottom: saved[3])
        guard frame.right - frame.left >= 400, frame.bottom - frame.top >= 300,
              MonitorFromRect(&frame, DWORD(MONITOR_DEFAULTTONULL)) != nil else { return false }
        SetWindowPos(handle, nil, frame.left, frame.top, frame.right - frame.left, frame.bottom - frame.top,
                     UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        return saved[4] == 1
    }

    private func savePlacement() {
        var placement = WINDOWPLACEMENT()
        placement.length = UINT(MemoryLayout<WINDOWPLACEMENT>.size)
        guard GetWindowPlacement(handle, &placement) else { return }
        // The size it has when not maximized, so that leaving full screen later gives a sensible window.
        var frame = placement.rcNormalPosition
        if placement.showCmd == UINT(SW_SHOWNORMAL) { GetWindowRect(handle, &frame) }
        let maximized = placement.showCmd == UINT(SW_SHOWMAXIMIZED) ? 1 : 0
        UserDefaults.standard.set("\(frame.left),\(frame.top),\(frame.right),\(frame.bottom),\(maximized)", forKey: Self.placementKey)
    }

    private func handle(message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT? {
        switch Int32(message) {
        case WM_SIZE:
            webView.resize()
            return 0
        case WM_MOVE, WM_MOVING:
            webView.moved()
            return nil
        case WM_SETFOCUS:
            webView.focus()
            return 0
        case WM_ACTIVATE:
            // Back from another program: the keyboard goes to the page again.
            if wParam & 0xFFFF != 0 { webView.focus() }
            return nil
        case WM_GETMINMAXINFO:
            // Smaller than this the sidebar and a gauge no longer fit next to each other.
            let scale = Int32(GetDpiForWindow(handle))
            let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: UInt(bitPattern: Int(lParam)))
            info?.pointee.ptMinTrackSize = POINT(x: 760 * scale / 96, y: 480 * scale / 96)
            return 0
        case WM_DPICHANGED:
            // Moved to a screen with another scaling: Windows suggests where the window should be now.
            if let suggested = UnsafePointer<RECT>(bitPattern: UInt(bitPattern: Int(lParam)))?.pointee {
                SetWindowPos(handle, nil, suggested.left, suggested.top, suggested.right - suggested.left,
                             suggested.bottom - suggested.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            }
            return 0
        case WM_SETTINGCHANGE:
            host_set_dark_title_bar(UnsafeMutableRawPointer(handle), host_dark_mode())
            return nil
        case WM_TIMER where wParam == Self.drainTimer:
            drain()
            return 0
        case WM_TIMER where wParam == Self.saveTimer:
            UserDefaults.standard.synchronize()
            return 0
        case WM_CLOSE:
            savePlacement()
            onClose?()
            UserDefaults.standard.synchronize()
            webView.close()
            DestroyWindow(handle)
            return 0
        case WM_DESTROY:
            KillTimer(handle, Self.drainTimer)
            KillTimer(handle, Self.saveTimer)
            PostQuitMessage(0)
            return 0
        default:
            return nil
        }
    }

    /// Runs what waits on the main actor. Not from inside itself: a message box opened by the
    /// model has a loop of its own, and work started there would run in the middle of other work.
    private func drain() {
        guard !draining else { return }
        draining = true
        mainqueue_drain()
        draining = false
    }

    /// Runs until the window is closed. Messages for the window and work for the main actor take turns.
    func run() -> Int32 {
        var message = MSG()
        var queue: HANDLE? = mainqueue_handle()
        while true {
            let signalled = MsgWaitForMultipleObjectsEx(queue == nil ? 0 : 1, &queue, INFINITE, DWORD(QS_ALLINPUT), DWORD(MWMO_INPUTAVAILABLE))
            if signalled == WAIT_OBJECT_0, queue != nil { drain() }
            while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
                if message.message == UINT(WM_QUIT) { return Int32(truncatingIfNeeded: Int(message.wParam)) }
                TranslateMessage(&message)
                DispatchMessageW(&message)
            }
        }
    }
}
