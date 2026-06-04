#include "CX11.h"

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/extensions/XTest.h>
#include <X11/extensions/Xfixes.h>
#include <X11/keysym.h>
#include <X11/XKBlib.h>
#include <string.h>
#include <stdlib.h>

struct cx11_display { Display *dpy; Window target; int last_x, last_y; };

/* Current pointer cursor sprite via XFIXES (the root framebuffer capture does
 * NOT include the cursor). Fills `out` with width*height*4 RGBA (premultiplied),
 * the hotspot, and a serial that changes when the cursor shape changes. Returns
 * 1 on success, 0 if XFIXES is unavailable or `out` is too small. */
int cx11_cursor_fetch(cx11_display *d, int *w, int *h, int *xhot, int *yhot,
                      unsigned long *serial, unsigned char *out, int out_cap) {
    if (!d || !d->dpy) return 0;
    int ev, er;
    if (!XFixesQueryExtension(d->dpy, &ev, &er)) return 0;
    XFixesCursorImage *img = XFixesGetCursorImage(d->dpy);
    if (!img) return 0;
    int ww = img->width, hh = img->height;
    int need = ww * hh * 4;
    if (ww <= 0 || hh <= 0 || need > out_cap) { XFree(img); return 0; }
    for (int i = 0; i < ww * hh; ++i) {
        unsigned long p = img->pixels[i];   /* premultiplied ARGB in the low 32 bits */
        out[i * 4 + 0] = (unsigned char)((p >> 16) & 0xff); /* R */
        out[i * 4 + 1] = (unsigned char)((p >> 8) & 0xff);  /* G */
        out[i * 4 + 2] = (unsigned char)(p & 0xff);         /* B */
        out[i * 4 + 3] = (unsigned char)((p >> 24) & 0xff); /* A */
    }
    if (w) *w = ww;
    if (h) *h = hh;
    if (xhot) *xhot = img->xhot;
    if (yhot) *yhot = img->yhot;
    if (serial) *serial = img->cursor_serial;
    XFree(img);
    return 1;
}

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

uint64_t cx11_root_window(cx11_display *d) {
    if (!d || !d->dpy) return 0;
    return (uint64_t)DefaultRootWindow(d->dpy);
}

int cx11_screen_size(cx11_display *d, int *w, int *h) {
    if (!d || !d->dpy) return 0;
    int s = DefaultScreen(d->dpy);
    if (w) *w = DisplayWidth(d->dpy, s);
    if (h) *h = DisplayHeight(d->dpy, s);
    return 1;
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
    d->target = (Window)win;   /* retained for compat; XTEST is server-level */
}

/* XTEST injects real server-level input on the default screen. Coordinates are
 * absolute root/screen pixels — and since we capture the whole root, the view's
 * pixel coordinates map 1:1. This is the path a real server (Xvfb) supports and
 * XQuartz 2.8.5 did not. */
void cx11_motion(cx11_display *d, int x, int y) {
    if (!d || !d->dpy) return;
    XTestFakeMotionEvent(d->dpy, DefaultScreen(d->dpy), x, y, CurrentTime);
    d->last_x = x; d->last_y = y;
    XFlush(d->dpy);
}

void cx11_button(cx11_display *d, int button, int is_press) {
    if (!d || !d->dpy) return;
    XTestFakeButtonEvent(d->dpy, (unsigned)button, is_press ? True : False, CurrentTime);
    XFlush(d->dpy);
}

void cx11_scroll(cx11_display *d, int up, int amount) {
    if (!d || !d->dpy) return;
    int button = up ? 4 : 5;          /* X11 wheel = buttons 4/5 */
    if (amount < 1) amount = 1;
    for (int i = 0; i < amount; ++i) {
        XTestFakeButtonEvent(d->dpy, (unsigned)button, True, CurrentTime);
        XTestFakeButtonEvent(d->dpy, (unsigned)button, False, CurrentTime);
    }
    XFlush(d->dpy);
}

void cx11_key_sym(cx11_display *d, uint32_t keysym, int is_press) {
    if (!d || !d->dpy) return;
    KeyCode kc = XKeysymToKeycode(d->dpy, (KeySym)keysym);
    if (kc == 0) return;
    XTestFakeKeyEvent(d->dpy, kc, is_press ? True : False, CurrentTime);
    XFlush(d->dpy);
}

/* The modifier mask (1<<i) that a given keycode belongs to, or 0. */
static unsigned int cx11_modmask_for_keycode(Display *dpy, KeyCode target) {
    if (!target) return 0;
    XModifierKeymap *mm = XGetModifierMapping(dpy);
    unsigned int mask = 0;
    if (mm) {
        for (int i = 0; i < 8; i++)
            for (int j = 0; j < mm->max_keypermod; j++)
                if (mm->modifiermap[i * mm->max_keypermod + j] == target) mask = (1u << i);
        XFreeModifiermap(mm);
    }
    return mask;
}

#define CX11_ISO_LEVEL3_SHIFT 0xfe03

void cx11_key_char(cx11_display *d, uint32_t keysym_in) {
    if (!d || !d->dpy) return;
    Display *dpy = d->dpy;
    KeySym keysym = (KeySym)keysym_in;

    /* Find the (keycode, group, level) that yields this keysym, scanning all
     * groups — some keymaps (e.g. the bundled 'de') place AltGr symbols like '@'
     * in a second group rather than group-1 level-2. We use native keycodes +
     * group locking so it survives nxproxy/nxagent (a remapped keycode would not). */
    int minK, maxK; XDisplayKeycodes(dpy, &minK, &maxK);
    KeyCode kc = 0; int grp = 0, lvl = 0;
    for (int k = minK; k <= maxK && !kc; k++)
        for (int g = 0; g < 4 && !kc; g++)
            for (int l = 0; l < 6; l++)
                if (XkbKeycodeToKeysym(dpy, (KeyCode)k, g, l) == keysym) {
                    kc = (KeyCode)k; grp = g; lvl = l; break;
                }
    if (!kc) return;

    int needShift  = (lvl & 1);                 /* odd levels need Shift */
    int needLevel3 = (lvl >= 2);                /* levels 2/3 need ISO_Level3_Shift */
    KeyCode shiftKc = XKeysymToKeycode(dpy, XK_Shift_L);
    KeyCode l3Kc    = XKeysymToKeycode(dpy, CX11_ISO_LEVEL3_SHIFT);
    unsigned int l3Mask = cx11_modmask_for_keycode(dpy, l3Kc);

    XkbStateRec st;
    int haveState = (XkbGetState(dpy, XkbUseCoreKbd, &st) == Success);
    int curGroup = haveState ? st.group : 0;
    int shiftOn  = haveState ? ((st.mods & ShiftMask) != 0) : 0;
    int l3On     = haveState ? (l3Mask && (st.mods & l3Mask)) : 0;

    if (grp != curGroup) XkbLockGroup(dpy, XkbUseCoreKbd, grp);
    if (shiftKc && needShift != shiftOn)
        XTestFakeKeyEvent(dpy, shiftKc, needShift ? True : False, CurrentTime);
    if (l3Kc && needLevel3 != l3On)
        XTestFakeKeyEvent(dpy, l3Kc, needLevel3 ? True : False, CurrentTime);
    XSync(dpy, False);

    XTestFakeKeyEvent(dpy, kc, True, CurrentTime);
    XTestFakeKeyEvent(dpy, kc, False, CurrentTime);

    /* Restore prior modifier + group state. */
    if (shiftKc && needShift != shiftOn)
        XTestFakeKeyEvent(dpy, shiftKc, shiftOn ? True : False, CurrentTime);
    if (l3Kc && needLevel3 != l3On)
        XTestFakeKeyEvent(dpy, l3Kc, l3On ? True : False, CurrentTime);
    if (grp != curGroup) XkbLockGroup(dpy, XkbUseCoreKbd, curGroup);
    XFlush(dpy);
}

void cx11_flush(cx11_display *d) {
    if (d && d->dpy) XFlush(d->dpy);
}
