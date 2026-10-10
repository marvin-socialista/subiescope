#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#define CINTERFACE
#include <windows.h>
#include <dwmapi.h>
#include <objbase.h>
#include <shobjidl.h>
#include <shellapi.h>
#include <stdlib.h>
#include <string.h>

#include "cwebview.h"

#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "uuid.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "shell32.lib")

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

void host_use_screen_scaling(void)
{
	SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
}

int host_dark_mode(void)
{
	DWORD light = 1, size = sizeof light;
	RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
	             L"AppsUseLightTheme", RRF_RT_REG_DWORD, NULL, &light, &size);
	return light == 0;
}

void host_set_dark_title_bar(void *window, int dark)
{
	BOOL value = dark ? TRUE : FALSE;
	DwmSetWindowAttribute((HWND)window, DWMWA_USE_IMMERSIVE_DARK_MODE, &value, sizeof value);
}

int host_choose_folder(void *window, const wchar_t *title, wchar_t *path, int size)
{
	int chosen = 0;
	IFileOpenDialog *dialog = NULL;
	CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
	if (FAILED(CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, (void **)&dialog)) || !dialog)
		return 0;
	FILEOPENDIALOGOPTIONS options = 0;
	IFileOpenDialog_GetOptions(dialog, &options);
	IFileOpenDialog_SetOptions(dialog, options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
	if (title && title[0])
		IFileOpenDialog_SetTitle(dialog, title);
	if (SUCCEEDED(IFileOpenDialog_Show(dialog, (HWND)window))) {
		IShellItem *item = NULL;
		if (SUCCEEDED(IFileOpenDialog_GetResult(dialog, &item)) && item) {
			LPWSTR name = NULL;
			if (SUCCEEDED(IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &name)) && name) {
				if ((int)wcslen(name) < size) {
					wcscpy(path, name);
					chosen = 1;
				}
				CoTaskMemFree(name);
			}
			IShellItem_Release(item);
		}
	}
	IFileOpenDialog_Release(dialog);
	return chosen;
}

int host_recycle(void *window, const wchar_t *path)
{
	// The list of files to delete ends with two zeros.
	size_t length = wcslen(path);
	wchar_t *list = calloc(length + 2, sizeof(wchar_t));
	if (!list)
		return 0;
	memcpy(list, path, length * sizeof(wchar_t));
	SHFILEOPSTRUCTW operation;
	memset(&operation, 0, sizeof operation);
	operation.hwnd = (HWND)window;
	operation.wFunc = FO_DELETE;
	operation.pFrom = list;
	// To the Recycle Bin, and quietly: the app has asked its own question already.
	operation.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI;
	int failed = SHFileOperationW(&operation);
	free(list);
	return failed == 0 && !operation.fAnyOperationsAborted;
}

void host_copy_text(void *window, const wchar_t *text)
{
	size_t bytes = (wcslen(text) + 1) * sizeof(wchar_t);
	HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
	if (!memory)
		return;
	void *target = GlobalLock(memory);
	if (!target) {
		GlobalFree(memory);
		return;
	}
	memcpy(target, text, bytes);
	GlobalUnlock(memory);
	if (!OpenClipboard((HWND)window)) {
		GlobalFree(memory);
		return;
	}
	EmptyClipboard();
	// The clipboard owns the memory from here on.
	if (!SetClipboardData(CF_UNICODETEXT, memory))
		GlobalFree(memory);
	CloseClipboard();
}

void *host_arrow_cursor(void)
{
	return LoadCursorW(NULL, IDC_ARROW);
}

void *host_app_icon(int for_title_bar)
{
	// Resource 1 is the icon the build script links in (Assets\AppIcon.ico).
	int size = GetSystemMetrics(for_title_bar ? SM_CXSMICON : SM_CXICON);
	return LoadImageW(GetModuleHandleW(NULL), MAKEINTRESOURCEW(1), IMAGE_ICON, size, size, LR_DEFAULTCOLOR);
}

#endif
