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

/* Root window of the default screen (the whole Xvfb display surface). */
uint64_t      cx11_root_window(cx11_display *d);

/* Default screen size in pixels. Returns 1 on success. */
int           cx11_screen_size(cx11_display *d, int *w, int *h);

/* Window size in pixels. Returns 1 on success. */
int           cx11_window_size(cx11_display *d, uint64_t win, int *w, int *h);

/* Absolute origin of the window on the root, for input coordinate mapping. */
int           cx11_window_root_origin(cx11_display *d, uint64_t win, int *rx, int *ry);

/* Capture the window into a caller-provided BGRA8 buffer (w*h*4 bytes).
 * Returns 1 on success, 0 on failure (e.g. window unmapped/obscured). */
int           cx11_capture_bgra(cx11_display *d, uint64_t win, int w, int h, uint8_t *out);

/* --- input injection (XTEST) ---
 * Against a real server (Xvfb) we use XTEST to synthesize genuine server-level
 * input. Coordinates are root/screen pixels (we capture the whole root, so view
 * pixels map 1:1). cx11_set_target() is retained for compatibility (no-op for
 * XTEST). */
void          cx11_set_target(cx11_display *d, uint64_t win);
void          cx11_motion(cx11_display *d, int x, int y);
void          cx11_button(cx11_display *d, int button, int is_press);
void          cx11_scroll(cx11_display *d, int up, int amount);
/* Map a keysym to a keycode and send a key press/release. */
void          cx11_key_sym(cx11_display *d, uint32_t keysym, int is_press);

/* Type a single character (by keysym): find the keycode + shift level on the
 * server keymap and tap it with the right modifiers (Shift / ISO_Level3_Shift),
 * preserving the current modifier state. Use this for printable input so that
 * layout-divergent symbols (e.g. '@' = AltGr+Q on X 'de' vs Option+L on a Mac)
 * are produced correctly. */
void          cx11_key_char(cx11_display *d, uint32_t keysym);

/* Flush pending X requests. */
void          cx11_flush(cx11_display *d);

/* Current pointer cursor sprite via XFIXES (not in the framebuffer capture).
 * Fills `out` (RGBA8, premultiplied), size, hotspot, and a change-serial.
 * Returns 1 on success, 0 if XFIXES is unavailable or `out` is too small. */
int           cx11_cursor_fetch(cx11_display *d, int *w, int *h, int *xhot, int *yhot,
                                unsigned long *serial, unsigned char *out, int out_cap);

/* --- clipboard bridge (its own X connection; selections are server-side) ---
 * Syncs the X CLIPBOARD selection with the macOS pasteboard. */
typedef struct cx11_clip cx11_clip;
cx11_clip *cx11_clip_open(const char *name);
void       cx11_clip_close(cx11_clip *c);
/* Own CLIPBOARD and serve this UTF-8 text to X apps that paste (mac -> X). */
void       cx11_clip_set_text(cx11_clip *c, const char *utf8);
/* Current X CLIPBOARD as UTF-8 (X -> mac). malloc'd; caller frees. NULL if none. */
char      *cx11_clip_get_text(cx11_clip *c);
/* Process incoming selection requests; call frequently. */
void       cx11_clip_pump(cx11_clip *c, int timeout_ms);

#endif /* CX11_H */
