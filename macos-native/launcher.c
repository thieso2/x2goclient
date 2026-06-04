/*
 * launcher.c — the self-contained x2goclient.app main executable.
 *
 * A compiled (Mach-O) launcher is the bundle's entry point so it can carry the
 * hardened-runtime entitlements required for notarization (a shell script
 * can't). It does nothing but exec the real Qt client (x2goclient.real),
 * passing our arguments through.
 *
 * The native macOS display path (a per-session headless Xvfb + a native Metal
 * viewer, no XQuartz) is owned entirely by the Qt client now: it knows each
 * session's geometry, so it starts a correctly-sized Xvfb and a viewer per
 * connection and tears them down with the session. See
 * macos-native/docs/adr/0001-per-session-xvfb-and-viewer.md and 0002.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach-o/dyld.h>

int main(int argc, char **argv) {
    char exe[4096]; uint32_t sz = sizeof(exe);
    if (_NSGetExecutablePath(exe, &sz) != 0) return 1;
    /* exe = .../Contents/MacOS/x2goclient -> strip two components to get Contents */
    char *s = strrchr(exe, '/'); if (s) *s = 0;       /* .../Contents/MacOS */
    s = strrchr(exe, '/'); if (s) *s = 0;             /* .../Contents       */

    char real[4096];
    snprintf(real, sizeof(real), "%s/MacOS/x2goclient.real", exe);

    char **real_argv = malloc(sizeof(char *) * (argc + 1));
    real_argv[0] = real;
    for (int i = 1; i < argc; i++) real_argv[i] = argv[i];
    real_argv[argc] = NULL;
    execv(real, real_argv);
    perror("execv x2goclient.real");
    return 1;
}
