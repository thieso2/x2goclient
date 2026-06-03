/*
 * CX11.h — thin C bridge over Xlib + XTEST for the native macOS client.
 *
 * Wraps the parts of Xlib that are macros or awkward from Swift (DefaultScreen,
 * RootWindow, image pixel access, XTEST input) behind plain C functions.
 *
 * This is the *bridge* layer of the native port: today it pulls frames from,
 * and injects input into, the X display that nxproxy renders the session onto.
 * The same C surface (capture a framebuffer, push input) is what a future
 * native NX/X-protocol decoder would implement to drop X11 entirely.
 */
#ifndef CX11_H
#define CX11_H

#include <stdint.h>

typedef struct cx11_display cx11_display;

/* Connection. name may be NULL (uses $DISPLAY) or e.g. ":0". */
cx11_display *cx11_open(const char *name);
void          cx11_close(cx11_display *d);

/* Find a top-level window whose WM name starts with `prefix` (e.g. "X2GO-").
 * Returns the window XID, or 0 if none found. */
uint64_t      cx11_find_window(cx11_display *d, const char *prefix);

/* Window size in pixels. Returns 1 on success. */
int           cx11_window_size(cx11_display *d, uint64_t win, int *w, int *h);

/* Absolute origin of the window on the root, for input coordinate mapping. */
int           cx11_window_root_origin(cx11_display *d, uint64_t win, int *rx, int *ry);

/* Capture the window into a caller-provided BGRA8 buffer (w*h*4 bytes).
 * Returns 1 on success, 0 on failure (e.g. window unmapped/obscured). */
int           cx11_capture_bgra(cx11_display *d, uint64_t win, int w, int h, uint8_t *out);

/* --- input injection via XTEST (operates on the display, root-relative) --- */
void          cx11_motion(cx11_display *d, int root_x, int root_y);
void          cx11_button(cx11_display *d, int button, int is_press);
void          cx11_scroll(cx11_display *d, int up, int amount);
/* Map a keysym to a keycode and fake a key press/release. */
void          cx11_key_sym(cx11_display *d, uint32_t keysym, int is_press);

/* Flush pending X requests. */
void          cx11_flush(cx11_display *d);

#endif /* CX11_H */
