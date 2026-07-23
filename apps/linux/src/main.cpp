#include "backend.h"
#include "debuglog.h"
#if defined(Q_OS_LINUX)
#include "mpris.h"
#elif defined(Q_OS_WIN)
#include "windowsmedia.h"
#endif

#include <QGuiApplication>
#include <QDir>
#include <QEvent>
#include <QFile>
#include <QIcon>
#include <QMouseEvent>
#include <QProcessEnvironment>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QSet>
#if defined(Q_OS_LINUX)
#include <QSocketNotifier>
#endif
#include <QWindow>
#include <QDebug>
#include <clocale>
#if defined(Q_OS_LINUX)
#include <cerrno>
#include <csignal>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>
#endif

namespace {
class NavigationMouseFilter final : public QObject
{
public:
    explicit NavigationMouseFilter(QObject *navigationTarget, QObject *parent = nullptr)
        : QObject(parent), m_navigationTarget(navigationTarget)
    {
    }

protected:
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        Q_UNUSED(watched)
        if (!m_navigationTarget || event->type() != QEvent::MouseButtonPress) return false;
        const auto button = static_cast<QMouseEvent *>(event)->button();
        const char *method = button == Qt::BackButton ? "navigateBack"
                           : button == Qt::ForwardButton ? "navigateForward" : nullptr;
        if (!method) return false;
        const bool handled = QMetaObject::invokeMethod(m_navigationTarget, method, Qt::DirectConnection);
        DebugLog::write(u"navigation", QStringLiteral("mouse button=%1 handled=%2")
                                           .arg(button == Qt::BackButton ? QStringLiteral("back")
                                                                         : QStringLiteral("forward"))
                                           .arg(handled));
        return handled;
    }

private:
    QObject *m_navigationTarget = nullptr;
};

#if defined(Q_OS_LINUX)
int terminationSignalWriteFd = -1;

void handleTerminationSignal(int signalNumber)
{
    const auto signalByte = static_cast<unsigned char>(signalNumber);
    if (terminationSignalWriteFd >= 0) {
        const auto ignored = ::write(terminationSignalWriteFd, &signalByte, sizeof(signalByte));
        (void)ignored;
    }
}

class TerminationSignalBridge final
{
public:
    explicit TerminationSignalBridge(QCoreApplication &application)
    {
        if (::pipe2(m_fds, O_CLOEXEC | O_NONBLOCK) != 0) {
            DebugLog::write(u"app", QStringLiteral("could not install termination signal bridge: %1")
                                         .arg(QString::fromLocal8Bit(std::strerror(errno))));
            return;
        }
        terminationSignalWriteFd = m_fds[1];
        m_notifier = new QSocketNotifier(m_fds[0], QSocketNotifier::Read, &application);
        QObject::connect(m_notifier, &QSocketNotifier::activated, &application,
                         [&application, readFd = m_fds[0]](QSocketDescriptor, QSocketNotifier::Type) {
            unsigned char signalByte = 0;
            while (::read(readFd, &signalByte, sizeof(signalByte)) > 0) {}
            DebugLog::write(u"app", QStringLiteral("termination signal received: %1").arg(signalByte));
            application.quit();
        });
        installHandlers();
        DebugLog::write(u"app", QStringLiteral("termination signal bridge installed"));
    }

    void installHandlers()
    {
        if (m_fds[1] < 0) return;
        std::signal(SIGINT, handleTerminationSignal);
        std::signal(SIGTERM, handleTerminationSignal);
    }

    ~TerminationSignalBridge()
    {
        std::signal(SIGINT, SIG_DFL);
        std::signal(SIGTERM, SIG_DFL);
        terminationSignalWriteFd = -1;
        if (m_fds[0] >= 0) ::close(m_fds[0]);
        if (m_fds[1] >= 0) ::close(m_fds[1]);
    }

private:
    int m_fds[2] = {-1, -1};
    QSocketNotifier *m_notifier = nullptr;
};
#endif

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
#if defined(Q_OS_LINUX)
    // Start listening before backend construction so a signal received during
    // startup remains queued until Qt's event loop can perform a clean exit.
    TerminationSignalBridge terminationSignals(app);
#endif
    QGuiApplication::setApplicationName(QStringLiteral("colorful"));
    QGuiApplication::setDesktopFileName(QStringLiteral("colorful"));
    QGuiApplication::setOrganizationName(QStringLiteral("colorful"));
    QGuiApplication::setWindowIcon(QIcon(QStringLiteral(":/assets/branding/colorful.svg")));
    DebugLog::write(u"app", QStringLiteral("colorful started; log=%1").arg(DebugLog::filePath()));
    qInfo().noquote() << "colorful debug log:" << DebugLog::filePath();
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

    auto *rootObject = engine.rootObjects().constFirst();
    auto *window = qobject_cast<QWindow *>(rootObject);
    NavigationMouseFilter navigationMouse(rootObject, &app);
    app.installEventFilter(&navigationMouse);
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
#if defined(Q_OS_LINUX)
    // Some multimedia libraries adjust process signal handling during
    // initialization, so restore our handlers once all subsystems are ready.
    terminationSignals.installHandlers();
#endif
    return app.exec();
}
