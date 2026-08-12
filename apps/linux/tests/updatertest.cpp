#include "updatemanager.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QFile>
#include <QHostAddress>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>

class UpdateManagerTest final : public QObject
{
public:
    explicit UpdateManagerTest(QObject *parent = nullptr) : QObject(parent)
    {
        connect(&m_server, &QTcpServer::newConnection, this, [this] {
            while (auto *socket = m_server.nextPendingConnection()) {
                ++m_requests;
                connect(socket, &QTcpSocket::readyRead, socket, [this, socket] {
                    socket->readAll();
                    if (socket->property("answered").toBool()) return;
                    socket->setProperty("answered", true);
                    if (m_requests == 1) {
                        socket->write("HTTP/1.1 200 OK\r\nContent-Length: 20\r\nConnection: close\r\n\r\npartial");
                        socket->flush();
                        socket->disconnectFromHost();
                        return;
                    }
                    socket->write("HTTP/1.1 200 OK\r\nContent-Length: 20\r\nConnection: close\r\n\r\ncolorful-update-test");
                    socket->disconnectFromHost();
                });
            }
        });
    }

    void start()
    {
        m_manager.m_allowLaunch = false;
        m_manager.m_openDownloadedLocation = false;
        m_manager.m_release.insert(QStringLiteral("version"), QStringLiteral("test"));
        const QUrl liveUrl(qEnvironmentVariable("COLORFUL_TEST_UPDATE_URL"));
        m_live = liveUrl.isValid() && !liveUrl.isEmpty();
        connect(&m_manager, &UpdateManager::changed, this, [this] {
            if (m_manager.state() == QStringLiteral("ready")) {
                QFile file(m_manager.m_downloadPath);
                if (!file.open(QIODevice::ReadOnly)) return fail("verified updater output was missing");
                if (m_live) {
                    if (file.size() != m_expectedSize) return fail("live updater output size did not match");
                } else if (m_requests != 2 || file.readAll() != QByteArrayLiteral("colorful-update-test")) {
                    return fail("retried updater output did not match");
                }
                file.close();
                QFile::remove(m_manager.m_downloadPath);
                qInfo(m_live
                          ? "updater downloaded and verified the live GitHub release asset"
                          : "updater recovered from an interrupted transfer and verified the retry");
                QCoreApplication::exit(0);
            }
            if (m_manager.state() == QStringLiteral("error"))
                fail(qPrintable(m_manager.status()));
        });
        if (m_live) {
            bool sizeOk = false;
            m_expectedSize = qEnvironmentVariableIntValue("COLORFUL_TEST_UPDATE_SIZE", &sizeOk);
            const auto digest = qEnvironmentVariable("COLORFUL_TEST_UPDATE_DIGEST");
            if (!sizeOk || m_expectedSize <= 0 || digest.size() != 64)
                return fail("live updater test variables were invalid");
            m_manager.beginDownload(liveUrl, QStringLiteral("colorful-live-test-setup.exe"),
                                    digest, m_expectedSize);
            return;
        }
        if (!m_server.listen(QHostAddress::LocalHost, 0)) return fail("test server failed to listen");
        const auto payload = QByteArrayLiteral("colorful-update-test");
        const auto digest = QString::fromLatin1(
            QCryptographicHash::hash(payload, QCryptographicHash::Sha256).toHex());
        m_manager.beginDownload(
            QUrl(QStringLiteral("http://127.0.0.1:%1/update.exe").arg(m_server.serverPort())),
            QStringLiteral("colorful-test-setup.exe"), digest, payload.size());
    }

private:
    void fail(const char *message)
    {
        qCritical("%s", message);
        QCoreApplication::exit(1);
    }

    QTcpServer m_server;
    UpdateManager m_manager;
    int m_requests = 0;
    qint64 m_expectedSize = 0;
    bool m_live = false;
};

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    UpdateManagerTest test;
    QTimer::singleShot(0, &test, [&test] { test.start(); });
    const auto timeoutMs = qEnvironmentVariableIsSet("COLORFUL_TEST_UPDATE_URL") ? 10 * 60 * 1000 : 15'000;
    QTimer::singleShot(timeoutMs, &app, [] {
        qCritical("updater retry test timed out");
        QCoreApplication::exit(1);
    });
    return app.exec();
}
