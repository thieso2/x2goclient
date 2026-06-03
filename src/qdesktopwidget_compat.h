/*
 * qdesktopwidget_compat.h — minimal QDesktopWidget shim for the Qt6 port.
 *
 * QDesktopWidget and QApplication::desktop() were removed in Qt6. This provides
 * a drop-in replacement covering exactly the small API surface x2goclient uses,
 * backed by QScreen / QGuiApplication. Call sites use x2go::desktop() in place
 * of QApplication::desktop(), and x2go::DesktopWidget in place of QDesktopWidget.
 *
 * This is deliberately a thin compatibility layer: the Qt UI is slated for
 * replacement by a native SwiftUI shell (Phase 2 of the macOS port), so this
 * minimizes churn rather than reworking every multi-monitor call site.
 */
#ifndef X2GO_QDESKTOPWIDGET_COMPAT_H
#define X2GO_QDESKTOPWIDGET_COMPAT_H

#include <QGuiApplication>
#include <QScreen>
#include <QRect>
#include <QPoint>
#include <QWidget>

namespace x2go {

class DesktopWidget {
public:
    int screenCount() const {
        return QGuiApplication::screens().size();
    }
    int numScreens() const {
        return screenCount();
    }

    QRect availableGeometry(int screen = -1) const {
        return screenAtIndex(screen)->availableGeometry();
    }
    QRect availableGeometry(const QWidget *w) const {
        return availableGeometry(screenNumber(w));
    }
    QRect screenGeometry(int screen = -1) const {
        return screenAtIndex(screen)->geometry();
    }
    QRect screenGeometry(const QWidget *w) const {
        return screenGeometry(screenNumber(w));
    }

    int physicalDpiX() const {
        QScreen *s = QGuiApplication::primaryScreen();
        return s ? qRound(s->physicalDotsPerInchX()) : 96;
    }
    int physicalDpiY() const {
        QScreen *s = QGuiApplication::primaryScreen();
        return s ? qRound(s->physicalDotsPerInchY()) : 96;
    }

    int depth() const {
        QScreen *s = QGuiApplication::primaryScreen();
        return s ? s->depth() : 24;
    }

    int primaryScreen() const {
        return QGuiApplication::screens().indexOf(QGuiApplication::primaryScreen());
    }

    int screenNumber(const QWidget *w) const {
        if (w && w->screen()) {
            int idx = QGuiApplication::screens().indexOf(w->screen());
            if (idx >= 0)
                return idx;
        }
        return primaryScreen();
    }
    int screenNumber(const QPoint &p) const {
        QScreen *s = QGuiApplication::screenAt(p);
        int idx = s ? QGuiApplication::screens().indexOf(s) : -1;
        return idx >= 0 ? idx : primaryScreen();
    }

private:
    static QScreen *screenAtIndex(int screen) {
        const QList<QScreen *> screens = QGuiApplication::screens();
        if (screen >= 0 && screen < screens.size())
            return screens.at(screen);
        return QGuiApplication::primaryScreen();
    }
};

inline DesktopWidget *desktop() {
    static DesktopWidget instance;
    return &instance;
}

} // namespace x2go

#endif // X2GO_QDESKTOPWIDGET_COMPAT_H
