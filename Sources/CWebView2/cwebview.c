// See include/cwebview.h. The WebView2 SDK itself is not in this repository:
// scripts\fetch-webview2.ps1 downloads it into .webview2 at the top of the repository.

#ifdef _WIN32

#if !__has_include("../../.webview2/WebView2.h")
#error "The WebView2 SDK is missing. Run scripts\fetch-webview2.ps1 once, then build again."
#endif

#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#define CINTERFACE
#define _CRT_SECURE_NO_WARNINGS

#include <windows.h>
#include <objbase.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../.webview2/WebView2.h"
#include "cwebview.h"

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "user32.lib")

// The interface ids, from WebView2.h. In C they are only declared there, not defined.
static const GUID id_unknown = { 0x00000000, 0x0000, 0x0000, { 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
static const GUID id_environment_handler = { 0x4e8a3389, 0xc9d8, 0x4bd2, { 0xb6, 0xb5, 0x12, 0x4f, 0xee, 0x6c, 0xc1, 0x4d } };
static const GUID id_controller_handler = { 0x6c4819f3, 0xc9b7, 0x4260, { 0x81, 0x27, 0xc9, 0xf5, 0xbd, 0xe7, 0xf6, 0x8c } };
static const GUID id_message_handler = { 0x57213f19, 0x00e6, 0x49fa, { 0x8e, 0x07, 0x89, 0x8e, 0xa0, 0x1e, 0xcb, 0xd2 } };
static const GUID id_view_3 = { 0xa0d6df20, 0x3b92, 0x416d, { 0xaa, 0x0c, 0x43, 0x7a, 0x9c, 0x72, 0x78, 0x57 } };
static const GUID id_controller_2 = { 0xc979903e, 0xd4ca, 0x4228, { 0x92, 0xeb, 0x47, 0xee, 0x3f, 0xa9, 0x6e, 0xab } };

struct webview {
	HWND window;
	HMODULE loader;
	ICoreWebView2Environment *environment;
	ICoreWebView2Controller *controller;
	ICoreWebView2 *view;
	webview_ready_fn ready;
	webview_message_fn message;
	void *context;
	int closed;
};

// One shape for the three callbacks WebView2 wants as COM objects. Each has the three
// methods of IUnknown and one of its own, Invoke.
struct handler_methods {
	HRESULT (STDMETHODCALLTYPE *QueryInterface)(void *self, REFIID id, void **object);
	ULONG (STDMETHODCALLTYPE *AddRef)(void *self);
	ULONG (STDMETHODCALLTYPE *Release)(void *self);
	void *Invoke;
};

struct handler {
	const struct handler_methods *methods;
	LONG references;
	const GUID *id;
	struct webview *owner;
};

static HRESULT STDMETHODCALLTYPE handler_query(void *self, REFIID id, void **object)
{
	struct handler *h = self;
	if (IsEqualGUID(id, &id_unknown) || IsEqualGUID(id, h->id)) {
		InterlockedIncrement(&h->references);
		*object = self;
		return S_OK;
	}
	*object = NULL;
	return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE handler_retain(void *self)
{
	return (ULONG)InterlockedIncrement(&((struct handler *)self)->references);
}

static ULONG STDMETHODCALLTYPE handler_release(void *self)
{
	LONG left = InterlockedDecrement(&((struct handler *)self)->references);
	if (left == 0)
		free(self);
	return (ULONG)left;
}

static struct handler *make_handler(struct webview *owner, const struct handler_methods *methods, const GUID *id)
{
	struct handler *h = calloc(1, sizeof *h);
	if (!h)
		return NULL;
	h->methods = methods;
	h->references = 1;
	h->id = id;
	h->owner = owner;
	return h;
}

static void report(struct webview *w, int ok, const char *what, HRESULT result)
{
	char detail[200];
	if (ok)
		detail[0] = 0;
	else
		snprintf(detail, sizeof detail, "%s (0x%08lX)", what, (unsigned long)result);
	if (w->ready)
		w->ready(w->context, ok, detail);
}

void webview_resize(webview *w)
{
	if (!w || !w->controller)
		return;
	RECT bounds;
	GetClientRect(w->window, &bounds);
	ICoreWebView2Controller_put_Bounds(w->controller, bounds);
}

static HRESULT STDMETHODCALLTYPE message_received(void *self, ICoreWebView2 *sender, ICoreWebView2WebMessageReceivedEventArgs *arguments)
{
	struct webview *w = ((struct handler *)self)->owner;
	LPWSTR wide = NULL;
	if (w->closed || !w->message || FAILED(ICoreWebView2WebMessageReceivedEventArgs_get_WebMessageAsJson(arguments, &wide)) || !wide)
		return S_OK;
	int size = WideCharToMultiByte(CP_UTF8, 0, wide, -1, NULL, 0, NULL, NULL);
	char *json = size > 0 ? malloc((size_t)size) : NULL;
	if (json) {
		WideCharToMultiByte(CP_UTF8, 0, wide, -1, json, size, NULL, NULL);
		w->message(w->context, json);
		free(json);
	}
	CoTaskMemFree(wide);
	return S_OK;
}

static const struct handler_methods message_methods = { handler_query, handler_retain, handler_release, (void *)message_received };

static HRESULT STDMETHODCALLTYPE controller_created(void *self, HRESULT result, ICoreWebView2Controller *controller)
{
	struct webview *w = ((struct handler *)self)->owner;
	if (w->closed)
		return S_OK;
	if (FAILED(result) || !controller) {
		report(w, 0, "Windows could not start the browser view", result);
		return S_OK;
	}
	w->controller = controller;
	ICoreWebView2Controller_AddRef(controller);
	result = ICoreWebView2Controller_get_CoreWebView2(controller, &w->view);
	if (FAILED(result) || !w->view) {
		report(w, 0, "The browser view has no page", result);
		return S_OK;
	}

	ICoreWebView2Settings *settings = NULL;
	if (SUCCEEDED(ICoreWebView2_get_Settings(w->view, &settings)) && settings) {
		// The page is the app's own window, not a web site: no status bar, no zooming, no browser menu.
		ICoreWebView2Settings_put_IsStatusBarEnabled(settings, FALSE);
		ICoreWebView2Settings_put_IsZoomControlEnabled(settings, FALSE);
		ICoreWebView2Settings_put_AreDefaultContextMenusEnabled(settings, FALSE);
		ICoreWebView2Settings_put_AreDevToolsEnabled(settings, FALSE);
		ICoreWebView2Settings_put_IsBuiltInErrorPageEnabled(settings, FALSE);
		ICoreWebView2Settings_Release(settings);
	}

	struct handler *messages = make_handler(w, &message_methods, &id_message_handler);
	if (messages) {
		EventRegistrationToken token;
		ICoreWebView2_add_WebMessageReceived(w->view, (ICoreWebView2WebMessageReceivedEventHandler *)messages, &token);
		handler_release(messages);
	}

	webview_resize(w);
	ICoreWebView2Controller_put_IsVisible(controller, TRUE);
	report(w, 1, "", S_OK);
	return S_OK;
}

static const struct handler_methods controller_methods = { handler_query, handler_retain, handler_release, (void *)controller_created };

static HRESULT STDMETHODCALLTYPE environment_created(void *self, HRESULT result, ICoreWebView2Environment *environment)
{
	struct webview *w = ((struct handler *)self)->owner;
	if (w->closed)
		return S_OK;
	if (FAILED(result) || !environment) {
		report(w, 0, "Windows could not start WebView2", result);
		return S_OK;
	}
	w->environment = environment;
	ICoreWebView2Environment_AddRef(environment);
	struct handler *next = make_handler(w, &controller_methods, &id_controller_handler);
	if (!next) {
		report(w, 0, "Out of memory", E_OUTOFMEMORY);
		return S_OK;
	}
	result = ICoreWebView2Environment_CreateCoreWebView2Controller(
		environment, w->window, (ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *)next);
	handler_release(next);
	if (FAILED(result))
		report(w, 0, "Windows could not start the browser view", result);
	return S_OK;
}

static const struct handler_methods environment_methods = { handler_query, handler_retain, handler_release, (void *)environment_created };

typedef HRESULT (STDAPICALLTYPE *create_environment_fn)(PCWSTR browser_folder, PCWSTR data_folder,
	ICoreWebView2EnvironmentOptions *options, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *handler);

webview *webview_create(void *window, const wchar_t *loader, const wchar_t *data_folder,
                        webview_ready_fn ready, webview_message_fn message, void *context)
{
	struct webview *w = calloc(1, sizeof *w);
	if (!w)
		return NULL;
	w->window = (HWND)window;
	w->ready = ready;
	w->message = message;
	w->context = context;

	// WebView2 is COM, and wants the kind of thread that has a message loop.
	CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);

	w->loader = LoadLibraryW(loader);
	create_environment_fn create = w->loader
		? (create_environment_fn)(void *)GetProcAddress(w->loader, "CreateCoreWebView2EnvironmentWithOptions") : NULL;
	if (!create) {
		report(w, 0, "WebView2Loader.dll is missing next to SubieScope.exe", HRESULT_FROM_WIN32(GetLastError()));
		return w;
	}
	struct handler *first = make_handler(w, &environment_methods, &id_environment_handler);
	if (!first) {
		report(w, 0, "Out of memory", E_OUTOFMEMORY);
		return w;
	}
	HRESULT result = create(NULL, data_folder, NULL, (ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *)first);
	handler_release(first);
	if (FAILED(result)) {
		// 0x80070002: the WebView2 runtime is not installed (it comes with Windows 11 and with Edge).
		report(w, 0, "The WebView2 runtime of Windows is not installed", result);
	}
	return w;
}

void webview_map_folder(webview *w, const wchar_t *host, const wchar_t *folder)
{
	if (!w || !w->view)
		return;
	ICoreWebView2_3 *view = NULL;
	if (SUCCEEDED(ICoreWebView2_QueryInterface(w->view, &id_view_3, (void **)&view)) && view) {
		ICoreWebView2_3_SetVirtualHostNameToFolderMapping(view, host, folder, COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW);
		ICoreWebView2_3_Release(view);
	}
}

void webview_navigate(webview *w, const wchar_t *url)
{
	if (w && w->view)
		ICoreWebView2_Navigate(w->view, url);
}

void webview_post_json(webview *w, const wchar_t *json)
{
	if (w && w->view && !w->closed)
		ICoreWebView2_PostWebMessageAsJson(w->view, json);
}

void webview_moved(webview *w)
{
	if (w && w->controller)
		ICoreWebView2Controller_NotifyParentWindowPositionChanged(w->controller);
}

void webview_focus(webview *w)
{
	if (w && w->controller)
		ICoreWebView2Controller_MoveFocus(w->controller, COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
}

void webview_set_background(webview *w, unsigned char red, unsigned char green, unsigned char blue)
{
	if (!w || !w->controller)
		return;
	ICoreWebView2Controller2 *controller = NULL;
	if (SUCCEEDED(ICoreWebView2Controller_QueryInterface(w->controller, &id_controller_2, (void **)&controller)) && controller) {
		COREWEBVIEW2_COLOR colour = { 255, red, green, blue };
		ICoreWebView2Controller2_put_DefaultBackgroundColor(controller, colour);
		ICoreWebView2Controller2_Release(controller);
	}
}

void webview_set_developer_mode(webview *w, int on)
{
	if (!w || !w->view)
		return;
	ICoreWebView2Settings *settings = NULL;
	if (SUCCEEDED(ICoreWebView2_get_Settings(w->view, &settings)) && settings) {
		ICoreWebView2Settings_put_AreDefaultContextMenusEnabled(settings, on ? TRUE : FALSE);
		ICoreWebView2Settings_put_AreDevToolsEnabled(settings, on ? TRUE : FALSE);
		ICoreWebView2Settings_Release(settings);
	}
}

void webview_open_developer_tools(webview *w)
{
	if (w && w->view)
		ICoreWebView2_OpenDevToolsWindow(w->view);
}

void webview_destroy(webview *w)
{
	if (!w)
		return;
	// A callback that is still on its way finds the view closed and does nothing. The small
	// struct itself is left for it to look at.
	w->closed = 1;
	w->ready = NULL;
	w->message = NULL;
	if (w->controller) {
		ICoreWebView2Controller_Close(w->controller);
		ICoreWebView2Controller_Release(w->controller);
		w->controller = NULL;
	}
	if (w->view) {
		ICoreWebView2_Release(w->view);
		w->view = NULL;
	}
	if (w->environment) {
		ICoreWebView2Environment_Release(w->environment);
		w->environment = NULL;
	}
}

#endif
