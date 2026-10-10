// A small C face on Microsoft's WebView2 (the browser view of Windows), so that Swift can
// put one in a window without speaking COM. Windows only.

#ifndef CWEBVIEW_H
#define CWEBVIEW_H

#ifdef _WIN32

#include <wchar.h>

typedef struct webview webview;

/// Called once, when the view is there (ok = 1) or could not be made (ok = 0, with why).
typedef void (*webview_ready_fn)(void *context, int ok, const char *detail);

/// Called for every message the page posts, as JSON text (UTF-8).
typedef void (*webview_message_fn)(void *context, const char *json);

/// Starts making a browser view that fills `window` (an HWND). `loader` is the path of
/// WebView2Loader.dll, `data_folder` where the view keeps its own files. Both callbacks
/// arrive on the thread that called this, from its message loop. Returns NULL (and calls
/// nothing) only when it is out of memory.
webview *webview_create(void *window, const wchar_t *loader, const wchar_t *data_folder,
                        webview_ready_fn ready, webview_message_fn message, void *context);

/// The functions below do nothing until `ready` has reported that the view is there.

/// Serves a folder of files to the page as https://<host>/.
void webview_map_folder(webview *view, const wchar_t *host, const wchar_t *folder);

void webview_navigate(webview *view, const wchar_t *url);

/// Hands a message to the page: it arrives there as an object, in a "message" event
/// of window.chrome.webview.
void webview_post_json(webview *view, const wchar_t *json);

/// Fits the view to its window again. Call when the window changes size.
void webview_resize(webview *view);

/// Call when the window has moved, so menus and tooltips open in the right place.
void webview_moved(webview *view);

/// Gives the keyboard to the page.
void webview_focus(webview *view);

/// The colour behind the page, shown before it has drawn itself.
void webview_set_background(webview *view, unsigned char red, unsigned char green, unsigned char blue);

/// Whether a right click opens the browser's own menu, and whether the developer tools can be opened.
void webview_set_developer_mode(webview *view, int on);

void webview_open_developer_tools(webview *view);

/// Closes the view and frees it.
void webview_destroy(webview *view);

#endif

#ifdef _WIN32

// Swift's main actor runs on libdispatch's main queue. In an app with a Windows message loop
// nothing empties that queue by itself, so the loop does it: it waits on this handle next to
// its messages, and calls mainqueue_drain when the handle is signalled.

/// An event handle that is signalled while the main queue has work waiting.
void *mainqueue_handle(void);

/// Runs what is waiting on the main queue. Main thread only, and never from inside itself.
void mainqueue_drain(void);

// Window chores that are macros or a second library away in the Windows headers.

/// Lets the window draw sharply on every screen, whatever its scaling. Call before making a window.
void host_use_screen_scaling(void);

/// 1 when Windows is set to dark mode for apps.
int host_dark_mode(void);

/// Gives the window a dark or a light title bar.
void host_set_dark_title_bar(void *window, int dark);

/// Asks for a folder with the system's dialog. 1 with the path in `path` (at most `size` characters), 0 when cancelled.
int host_choose_folder(void *window, const wchar_t *title, wchar_t *path, int size);

/// Moves a file to the Recycle Bin, without asking. 1 when it is there now.
int host_recycle(void *window, const wchar_t *path);

/// Puts text on the clipboard.
void host_copy_text(void *window, const wchar_t *text);

/// The standard arrow cursor, and the program's own icon (NULL when it was built without one).
void *host_arrow_cursor(void);
void *host_app_icon(int for_title_bar);

#endif
#endif
