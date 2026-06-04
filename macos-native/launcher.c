/*
 * launcher.c — the self-contained x2goclient.app main executable.
 *
 * A compiled (Mach-O) launcher is required for notarization/hardened runtime
 * (a shell script can't carry entitlements). It starts the bundled Xvfb, sets
 * the keyboard layout to match macOS, starts the native Metal capture window,
 * then execs the real Qt client (x2goclient.real). No XQuartz needed.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <spawn.h>
#include <mach-o/dyld.h>
#include <ApplicationServices/ApplicationServices.h>  /* CGDisplay* */

extern char **environ;

/* Logical (point) size of the main display, so the native Metal window — which
 * sizes itself to the Xvfb root — fills the screen at 1:1 points. Falls back to
 * 1280x800. Clamped to sane bounds. */
static void main_display_size(int *w, int *h) {
    CGDirectDisplayID d = CGMainDisplayID();
    size_t pw = CGDisplayPixelsWide(d), ph = CGDisplayPixelsHigh(d);
    *w = (pw >= 640 && pw <= 8192) ? (int)pw : 1280;
    *h = (ph >= 480 && ph <= 8192) ? (int)ph : 800;
}

/* Map the current macOS keyboard layout to an XKB layout code. */
static const char *mac_xkb(void) {
    FILE *p = popen("defaults read ~/Library/Preferences/com.apple.HIToolbox.plist "
                    "AppleCurrentKeyboardLayoutInputSourceID 2>/dev/null", "r");
    static char xkb[8] = "us";
    char buf[256] = {0};
    if (p) { (void)fread(buf, 1, sizeof(buf) - 1, p); pclose(p); }
    if      (strstr(buf, "German"))     strcpy(xkb, "de");
    else if (strstr(buf, "Swiss"))      strcpy(xkb, "ch");
    else if (strstr(buf, "British"))    strcpy(xkb, "gb");
    else if (strstr(buf, "French"))     strcpy(xkb, "fr");
    else if (strstr(buf, "Spanish"))    strcpy(xkb, "es");
    else if (strstr(buf, "Italian"))    strcpy(xkb, "it");
    else if (strstr(buf, "Portuguese")) strcpy(xkb, "pt");
    else if (strstr(buf, "Dutch"))      strcpy(xkb, "nl");
    else if (strstr(buf, "Norwegian"))  strcpy(xkb, "no");
    else if (strstr(buf, "Swedish"))    strcpy(xkb, "se");
    else if (strstr(buf, "Danish"))     strcpy(xkb, "dk");
    else if (strstr(buf, "Finnish"))    strcpy(xkb, "fi");
    else                                strcpy(xkb, "us");
    return xkb;
}

int main(int argc, char **argv) {
    char exe[4096]; uint32_t sz = sizeof(exe);
    if (_NSGetExecutablePath(exe, &sz) != 0) return 1;
    /* exe = .../Contents/MacOS/x2goclient -> strip two components to get Contents */
    char *s = strrchr(exe, '/'); if (s) *s = 0;       /* .../Contents/MacOS */
    s = strrchr(exe, '/'); if (s) *s = 0;             /* .../Contents       */
    const char *C = exe;

    char bin[4096], xvfb[4096], setxk[4096], native[4096], real[4096], fonts[4096], xkb[4096];
    snprintf(bin,    sizeof(bin),    "%s/Resources/x11/bin", C);
    snprintf(xvfb,   sizeof(xvfb),   "%s/Xvfb", bin);
    snprintf(setxk,  sizeof(setxk),  "%s/setxkbmap", bin);
    snprintf(native, sizeof(native), "%s/exe/X2GoNative", C);
    snprintf(real,   sizeof(real),   "%s/MacOS/x2goclient.real", C);
    snprintf(fonts,  sizeof(fonts),  "%s/Resources/x11/fonts/misc", C);
    snprintf(xkb,    sizeof(xkb),    "%s/Resources/x11/xkb", C);

    /* pick a free display */
    int disp = 99; char lock[64];
    for (; disp < 120; disp++) {
        snprintf(lock, sizeof(lock), "/tmp/.X%d-lock", disp);
        if (access(lock, F_OK) != 0) break;
    }
    char dispstr[16]; snprintf(dispstr, sizeof(dispstr), ":%d", disp);
    setenv("XKB_BINDIR", bin, 1);
    setenv("DISPLAY", dispstr, 1);
    /* The session must render at exactly the Xvfb root size or the nxproxy replay
     * corrupts (overlapping window/panel trails). We can't know the user's
     * profile geometry before Xvfb starts, so size Xvfb to the screen and force
     * the session fullscreen (-> session geometry == Xvfb root). */
    setenv("X2GO_FORCE_FULLSCREEN", "1", 1);

    int sw, sh; main_display_size(&sw, &sh);
    char screen[32]; snprintf(screen, sizeof(screen), "%dx%dx24", sw, sh);

    pid_t pid;
    char *xvfb_argv[] = { xvfb, dispstr, "-screen", "0", screen,
                          "-ac", "-noreset", "-fp", fonts, "-xkbdir", xkb, NULL };
    posix_spawn(&pid, xvfb, NULL, NULL, xvfb_argv, environ);
    sleep(2);

    char *layout = (char *)mac_xkb();
    char *sx_argv[] = { setxk, layout, NULL };
    posix_spawn(&pid, setxk, NULL, NULL, sx_argv, environ);

    char *nat_argv[] = { native, "--display", dispstr, NULL };
    posix_spawn(&pid, native, NULL, NULL, nat_argv, environ);

    /* exec the real Qt client, passing through our args */
    char **real_argv = malloc(sizeof(char *) * (argc + 1));
    real_argv[0] = real;
    for (int i = 1; i < argc; i++) real_argv[i] = argv[i];
    real_argv[argc] = NULL;
    execv(real, real_argv);
    perror("execv x2goclient.real");
    return 1;
}
