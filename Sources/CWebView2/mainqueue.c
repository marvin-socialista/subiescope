#ifdef _WIN32

#include "cwebview.h"

// What CoreFoundation's run loop uses for the same job. Both come from dispatch.dll.
extern void *_dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *message);

void *mainqueue_handle(void)
{
	return _dispatch_get_main_queue_handle_4CF();
}

void mainqueue_drain(void)
{
	_dispatch_main_queue_callback_4CF(0);
}

#endif
