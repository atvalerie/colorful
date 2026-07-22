#include "backend.h"
#if defined(Q_OS_LINUX)
#include "mpris.h"
#elif defined(Q_OS_WIN)
#include "windowsmedia.h"
#endif

#include <QGuiApplication>
#include <QDir>
#include <QFile>
#include <QIcon>
#include <QProcessEnvironment>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QSet>
#include <QWindow>
#include <clocale>

namespace {
void importEnvironmentFile(const QString &path, const QSet<QString> &inherited)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) return;
    while (!file.atEnd()) {
        auto line = QString::fromUtf8(file.readLine()).trimmed();
        if (line.isEmpty() || line.startsWith(u'#')) continue;
        if (line.startsWith(QStringLiteral("export "))) line = line.sliced(7).trimmed();
        const auto separator = line.indexOf(u'=');
        if (separator <= 0) continue;
        const auto name = line.left(separator).trimmed();
        if (inherited.contains(name)) continue;
        auto value = line.sliced(separator + 1).trimmed();
        if (value.size() >= 2 && ((value.front() == u'\"' && value.back() == u'\"')
                                 || (value.front() == u'\'' && value.back() == u'\'')))
            value = value.sliced(1, value.size() - 2);
        if (!name.isEmpty()) qputenv(name.toUtf8(), value.toUtf8());
    }
}

void importDevelopmentEnvironment()
{
    const auto inheritedKeys = QProcessEnvironment::systemEnvironment().keys();
    const QSet<QString> inherited(inheritedKeys.cbegin(), inheritedKeys.cend());
    const QDir sourceRoot(QString::fromUtf8(COLORFUL_SOURCE_DIR));
    // Match the convenience launchers, while preserving explicit process
    // environment values. Packaged builds may optionally place an .env next
    // to the executable; public provider clients do not require one.
    importEnvironmentFile(sourceRoot.filePath(QStringLiteral("../mocha/.env")), inherited);
    importEnvironmentFile(sourceRoot.filePath(QStringLiteral(".env")), inherited);
    importEnvironmentFile(QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral(".env")), inherited);
}
}

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    QGuiApplication::setApplicationName(QStringLiteral("colorful"));
    QGuiApplication::setDesktopFileName(QStringLiteral("colorful"));
    QGuiApplication::setOrganizationName(QStringLiteral("colorful"));
    QGuiApplication::setWindowIcon(QIcon(QStringLiteral(":/assets/branding/colorful.svg")));
    QQuickStyle::setStyle(QStringLiteral("Basic"));
    importDevelopmentEnvironment();
    // Qt adopts the user's locale during application construction. libmpv's
    // client API requires the process-wide numeric locale to remain C so
    // option and property values always use a decimal point.
    std::setlocale(LC_NUMERIC, "C");

    Backend backend;
    QObject::connect(&app, &QCoreApplication::aboutToQuit, &backend, [&backend] {
        backend.shutdownDiscordPresence();
    });
#if defined(Q_OS_LINUX)
    MprisService mpris(&backend);
#endif
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("colorful"), &backend);
    engine.loadFromModule(QStringLiteral("colorful"), QStringLiteral("Main"));
    if (engine.rootObjects().isEmpty()) return 1;

    auto *window = qobject_cast<QWindow *>(engine.rootObjects().constFirst());
#if defined(Q_OS_WIN)
    WindowsMediaSession windowsMedia(&backend, window);
#endif
    QObject::connect(&backend, &Backend::quitRequested, &app, &QCoreApplication::quit);
    QObject::connect(&backend, &Backend::raiseRequested, window, [window] {
        if (!window) return;
        window->show();
        window->raise();
        window->requestActivate();
    });
    return app.exec();
}
