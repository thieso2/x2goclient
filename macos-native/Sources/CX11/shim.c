#include "CX11.h"

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/extensions/XTest.h>
#include <X11/keysym.h>
#include <string.h>
#include <stdlib.h>

struct cx11_display { Display *dpy; Window target; int last_x, last_y; };

cx11_display *cx11_open(const char *name) {
    Display *dpy = XOpenDisplay(name);
    if (!dpy) return NULL;
    cx11_display *d = (cx11_display *)calloc(1, sizeof(cx11_display));
    d->dpy = dpy;
    return d;
}

void cx11_close(cx11_display *d) {
    if (!d) return;
    if (d->dpy) XCloseDisplay(d->dpy);
    free(d);
}

/* Recursive search for a top-level window whose WM_NAME starts with prefix. */
static Window find_recursive(Display *dpy, Window root, const char *prefix) {
    char *name = NULL;
    if (XFetchName(dpy, root, &name) && name) {
        int match = strncmp(name, prefix, strlen(prefix)) == 0;
        XFree(name);
        if (match) return root;
    }
    Window dummy, *children = NULL;
    unsigned int n = 0;
    if (XQueryTree(dpy, root, &dummy, &dummy, &children, &n) && children) {
        Window found = 0;
        for (unsigned int i = 0; i < n && !found; ++i)
            found = find_recursive(dpy, children[i], prefix);
        XFree(children);
        if (found) return found;
    }
    return 0;
}

uint64_t cx11_find_window(cx11_display *d, const char *prefix) {
    if (!d || !d->dpy) return 0;
    Window root = DefaultRootWindow(d->dpy);
    return (uint64_t)find_recursive(d->dpy, root, prefix);
}

int cx11_window_size(cx11_display *d, uint64_t win, int *w, int *h) {
    if (!d || !d->dpy) return 0;
    XWindowAttributes a;
    if (!XGetWindowAttributes(d->dpy, (Window)win, &a)) return 0;
    if (w) *w = a.width;
    if (h) *h = a.height;
    return 1;
}

int cx11_window_root_origin(cx11_display *d, uint64_t win, int *rx, int *ry) {
    if (!d || !d->dpy) return 0;
    Window child;
    int x = 0, y = 0;
    Window root = DefaultRootWindow(d->dpy);
    if (!XTranslateCoordinates(d->dpy, (Window)win, root, 0, 0, &x, &y, &child)) return 0;
    if (rx) *rx = x;
    if (ry) *ry = y;
    return 1;
}

int cx11_capture_bgra(cx11_display *d, uint64_t win, int w, int h, uint8_t *out) {
    if (!d || !d->dpy || !out) return 0;
    XImage *img = XGetImage(d->dpy, (Window)win, 0, 0, (unsigned)w, (unsigned)h, AllPlanes, ZPixmap);
    if (!img) return 0;

    int ok = 1;
    /* Fast path: 32 bpp, standard TrueColor masks, LSBFirst -> already BGRA in
     * memory; just force opaque alpha. */
    if (img->bits_per_pixel == 32 && img->byte_order == LSBFirst &&
        img->red_mask == 0xff0000 && img->green_mask == 0x00ff00 && img->blue_mask == 0x0000ff) {
        for (int y = 0; y < h; ++y) {
            const uint8_t *src = (const uint8_t *)(img->data + (size_t)y * img->bytes_per_line);
            uint8_t *dst = out + (size_t)y * w * 4;
            memcpy(dst, src, (size_t)w * 4);
            for (int x = 0; x < w; ++x) dst[x * 4 + 3] = 0xff;
        }
    } else {
        /* Correct-but-slow fallback via XGetPixel + color decode. */
        Visual *vis = DefaultVisual(d->dpy, DefaultScreen(d->dpy));
        (void)vis;
        for (int y = 0; y < h; ++y) {
            uint8_t *dst = out + (size_t)y * w * 4;
            for (int x = 0; x < w; ++x) {
                unsigned long p = XGetPixel(img, x, y);
                uint8_t r = (uint8_t)((p & img->red_mask)   >> 16);
                uint8_t g = (uint8_t)((p & img->green_mask) >> 8);
                uint8_t b = (uint8_t)( p & img->blue_mask);
                dst[x * 4 + 0] = b;
                dst[x * 4 + 1] = g;
                dst[x * 4 + 2] = r;
                dst[x * 4 + 3] = 0xff;
            }
        }
    }
    XDestroyImage(img);
    return ok;
}

void cx11_set_target(cx11_display *d, uint64_t win) {
    if (!d) return;
    d->target = (Window)win;
}

static unsigned int pointer_state(cx11_display *d) {
    Window r, c; int rx, ry, wx, wy; unsigned int mask = 0;
    XQueryPointer(d->dpy, d->target ? d->target : DefaultRootWindow(d->dpy),
                  &r, &c, &rx, &ry, &wx, &wy, &mask);
    return mask;
}

void cx11_motion(cx11_display *d, int x, int y) {
    if (!d || !d->dpy || !d->target) return;
    XWarpPointer(d->dpy, None, d->target, 0, 0, 0, 0, x, y);
    d->last_x = x; d->last_y = y;
    XFlush(d->dpy);
}

static void send_button(cx11_display *d, int button, Bool press) {
    Window root = DefaultRootWindow(d->dpy);
    int rx = 0, ry = 0; Window child;
    XTranslateCoordinates(d->dpy, d->target, root, d->last_x, d->last_y, &rx, &ry, &child);
    XButtonEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = press ? ButtonPress : ButtonRelease;
    ev.display = d->dpy;
    ev.window = d->target;
    ev.root = root;
    ev.subwindow = None;
    ev.time = CurrentTime;
    ev.x = d->last_x; ev.y = d->last_y;
    ev.x_root = rx; ev.y_root = ry;
    ev.state = pointer_state(d);
    ev.button = (unsigned)button;
    ev.same_screen = True;
    XSendEvent(d->dpy, d->target, True,
               press ? ButtonPressMask : ButtonReleaseMask, (XEvent *)&ev);
    XFlush(d->dpy);
}

void cx11_button(cx11_display *d, int button, int is_press) {
    if (!d || !d->dpy || !d->target) return;
    send_button(d, button, is_press ? True : False);
}

void cx11_scroll(cx11_display *d, int up, int amount) {
    if (!d || !d->dpy || !d->target) return;
    int button = up ? 4 : 5;          /* X11 wheel = buttons 4/5 */
    if (amount < 1) amount = 1;
    for (int i = 0; i < amount; ++i) {
        send_button(d, button, True);
        send_button(d, button, False);
    }
}

void cx11_key_sym(cx11_display *d, uint32_t keysym, int is_press) {
    if (!d || !d->dpy || !d->target) return;
    KeyCode kc = XKeysymToKeycode(d->dpy, (KeySym)keysym);
    if (kc == 0) return;
    Window root = DefaultRootWindow(d->dpy);
    int rx = 0, ry = 0; Window child;
    XTranslateCoordinates(d->dpy, d->target, root, d->last_x, d->last_y, &rx, &ry, &child);
    XKeyEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = is_press ? KeyPress : KeyRelease;
    ev.display = d->dpy;
    ev.window = d->target;
    ev.root = root;
    ev.subwindow = None;
    ev.time = CurrentTime;
    ev.x = d->last_x; ev.y = d->last_y;
    ev.x_root = rx; ev.y_root = ry;
    ev.state = pointer_state(d);
    ev.keycode = kc;
    ev.same_screen = True;
    XSendEvent(d->dpy, d->target, True,
               is_press ? KeyPressMask : KeyReleaseMask, (XEvent *)&ev);
    XFlush(d->dpy);
}

void cx11_flush(cx11_display *d) {
    if (d && d->dpy) XFlush(d->dpy);
}
