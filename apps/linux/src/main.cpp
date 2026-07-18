#include "backend.h"
#include "mpris.h"

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QWindow>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    QGuiApplication::setApplicationName(QStringLiteral("Colorful"));
    QGuiApplication::setDesktopFileName(QStringLiteral("colorful"));
    QGuiApplication::setOrganizationName(QStringLiteral("Colorful"));
    QQuickStyle::setStyle(QStringLiteral("Basic"));

    Backend backend;
    MprisService mpris(&backend);
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("colorful"), &backend);
    engine.loadFromModule(QStringLiteral("Colorful"), QStringLiteral("Main"));
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
