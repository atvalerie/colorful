#include "backend.h"
#include "mpris.h"

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QWindow>
#include <clocale>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    QGuiApplication::setApplicationName(QStringLiteral("colorful"));
    QGuiApplication::setDesktopFileName(QStringLiteral("colorful"));
    QGuiApplication::setOrganizationName(QStringLiteral("colorful"));
    QQuickStyle::setStyle(QStringLiteral("Basic"));
    // Qt adopts the user's locale during application construction. libmpv's
    // client API requires the process-wide numeric locale to remain C so
    // option and property values always use a decimal point.
    std::setlocale(LC_NUMERIC, "C");

    Backend backend;
    MprisService mpris(&backend);
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("colorful"), &backend);
    engine.loadFromModule(QStringLiteral("colorful"), QStringLiteral("Main"));
    if (engine.rootObjects().isEmpty()) return 1;

    auto *window = qobject_cast<QWindow *>(engine.rootObjects().constFirst());
    QObject::connect(&backend, &Backend::quitRequested, &app, &QCoreApplication::quit);
    QObject::connect(&backend, &Backend::raiseRequested, window, [window] {
        if (!window) return;
        window->show();
        window->raise();
        window->requestActivate();
    });
    return app.exec();
}
