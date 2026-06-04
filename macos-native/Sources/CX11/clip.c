/*
 * clip.c — X11 CLIPBOARD <-> (caller) bridge for the native client.
 *
 * Uses its OWN X connection (selections are server-side, so a separate
 * connection is fine and avoids threading races with the capture connection).
 * - cx11_clip_set_text: take ownership of CLIPBOARD and serve `text` to X apps
 *   that paste (mac -> X).
 * - cx11_clip_get_text: read the current X CLIPBOARD as UTF-8 (X -> mac).
 * - cx11_clip_pump: process incoming SelectionRequest/Clear events; call often.
 */
#include "CX11.h"

#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <string.h>
#include <stdlib.h>
#include <poll.h>

struct cx11_clip {
    Display *dpy;
    Window   win;
    Atom CLIPBOARD, UTF8, TARGETS, PROP, INCR;
    char *owned;   /* text we serve while we own CLIPBOARD (malloc'd) */
};

cx11_clip *cx11_clip_open(const char *name) {
    Display *dpy = XOpenDisplay(name);
    if (!dpy) return NULL;
    cx11_clip *c = (cx11_clip *)calloc(1, sizeof(cx11_clip));
    c->dpy = dpy;
    int s = DefaultScreen(dpy);
    c->win = XCreateSimpleWindow(dpy, RootWindow(dpy, s), 0, 0, 1, 1, 0, 0, 0);
    c->CLIPBOARD = XInternAtom(dpy, "CLIPBOARD", False);
    c->UTF8      = XInternAtom(dpy, "UTF8_STRING", False);
    c->TARGETS   = XInternAtom(dpy, "TARGETS", False);
    c->PROP      = XInternAtom(dpy, "CX11_CLIP_PROP", False);
    c->INCR      = XInternAtom(dpy, "INCR", False);
    return c;
}

void cx11_clip_close(cx11_clip *c) {
    if (!c) return;
    if (c->owned) free(c->owned);
    if (c->dpy) { XDestroyWindow(c->dpy, c->win); XCloseDisplay(c->dpy); }
    free(c);
}

void cx11_clip_set_text(cx11_clip *c, const char *utf8) {
    if (!c || !c->dpy) return;
    if (c->owned) free(c->owned);
    c->owned = strdup(utf8 ? utf8 : "");
    XSetSelectionOwner(c->dpy, c->CLIPBOARD, c->win, CurrentTime);
    XFlush(c->dpy);
}

/* Reply to one SelectionRequest with our owned text (or the TARGETS list). */
static void serve_request(cx11_clip *c, XSelectionRequestEvent *req) {
    XSelectionEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = SelectionNotify;
    ev.display = req->display;
    ev.requestor = req->requestor;
    ev.selection = req->selection;
    ev.target = req->target;
    ev.time = req->time;
    ev.property = req->property ? req->property : req->target;
    if (req->target == c->TARGETS) {
        Atom targets[3] = { c->TARGETS, c->UTF8, XA_STRING };
        XChangeProperty(c->dpy, req->requestor, ev.property, XA_ATOM, 32,
                        PropModeReplace, (unsigned char *)targets, 3);
    } else if ((req->target == c->UTF8 || req->target == XA_STRING) && c->owned) {
        XChangeProperty(c->dpy, req->requestor, ev.property, req->target, 8,
                        PropModeReplace, (unsigned char *)c->owned, (int)strlen(c->owned));
    } else {
        ev.property = None; /* refuse */
    }
    XSendEvent(c->dpy, req->requestor, False, 0, (XEvent *)&ev);
    XFlush(c->dpy);
}

static void drain(cx11_clip *c) {
    while (XPending(c->dpy)) {
        XEvent e; XNextEvent(c->dpy, &e);
        if (e.type == SelectionRequest) serve_request(c, &e.xselectionrequest);
        else if (e.type == SelectionClear) { if (c->owned) { free(c->owned); c->owned = NULL; } }
    }
}

void cx11_clip_pump(cx11_clip *c, int timeout_ms) {
    if (!c || !c->dpy) return;
    drain(c);
    if (timeout_ms > 0) {
        struct pollfd p = { ConnectionNumber(c->dpy), POLLIN, 0 };
        if (poll(&p, 1, timeout_ms) > 0) drain(c);
    }
}

char *cx11_clip_get_text(cx11_clip *c) {
    if (!c || !c->dpy) return NULL;
    Window owner = XGetSelectionOwner(c->dpy, c->CLIPBOARD);
    if (owner == None) return NULL;
    if (owner == c->win) return c->owned ? strdup(c->owned) : NULL;

    XConvertSelection(c->dpy, c->CLIPBOARD, c->UTF8, c->PROP, c->win, CurrentTime);
    XFlush(c->dpy);
    int fd = ConnectionNumber(c->dpy);
    for (int tries = 0; tries < 50; ++tries) {
        while (XPending(c->dpy)) {
            XEvent e; XNextEvent(c->dpy, &e);
            if (e.type == SelectionRequest) { serve_request(c, &e.xselectionrequest); continue; }
            if (e.type == SelectionClear) { if (c->owned) { free(c->owned); c->owned = NULL; } continue; }
            if (e.type == SelectionNotify) {
                if (e.xselection.property == None) return NULL;
                Atom type; int fmt; unsigned long nitems, after; unsigned char *data = NULL;
                if (XGetWindowProperty(c->dpy, c->win, c->PROP, 0, (~0L), True, AnyPropertyType,
                                       &type, &fmt, &nitems, &after, &data) == Success && data) {
                    if (type == c->INCR) { XFree(data); return NULL; } /* skip INCR for now */
                    char *out = (char *)malloc(nitems + 1);
                    memcpy(out, data, nitems); out[nitems] = 0;
                    XFree(data);
                    return out;
                }
                return NULL;
            }
        }
        struct pollfd p = { fd, POLLIN, 0 };
        poll(&p, 1, 20);
    }
    return NULL;
}
