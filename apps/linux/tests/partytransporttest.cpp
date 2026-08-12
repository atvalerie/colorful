#include "partycorebridge.h"
#include "websocketclient.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QTimer>

class PartyTransportTest final : public QObject
{
    Q_OBJECT
public:
    explicit PartyTransportTest(QObject *parent = nullptr)
        : QObject(parent), m_hostSocket(this), m_guestSocket(this)
    {
        connect(&m_hostSocket, &WebSocketClient::connectedChanged, this, [this](bool) { startJoin(); });
        connect(&m_guestSocket, &WebSocketClient::connectedChanged, this, [this](bool) { startJoin(); });
        connect(&m_hostSocket, &WebSocketClient::binaryMessage, this, &PartyTransportTest::hostReceived);
        connect(&m_guestSocket, &WebSocketClient::binaryMessage, this, &PartyTransportTest::guestReceived);
        connect(&m_hostSocket, &WebSocketClient::failed, this, &PartyTransportTest::fail);
        connect(&m_guestSocket, &WebSocketClient::failed, this, &PartyTransportTest::fail);
    }

    void start()
    {
        m_base = qEnvironmentVariable("COLORFUL_TEST_RELAY", QStringLiteral("http://127.0.0.1:8787"));
        QNetworkRequest request(QUrl(m_base + QStringLiteral("/v1/party-sessions")));
        request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
        auto *reply = m_network.post(request, QByteArrayLiteral("{\"ttlSeconds\":300}"));
        connect(reply, &QNetworkReply::finished, this, [this, reply] {
            const auto document = QJsonDocument::fromJson(reply->readAll());
            const auto status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            reply->deleteLater();
            const auto relay = document.object().value(QStringLiteral("party")).toObject();
            if (status != 201 || relay.isEmpty()) return fail(QStringLiteral("relay allocation failed"));
            m_session = relay.value(QStringLiteral("sessionId")).toString();
            const auto expires = relay.value(QStringLiteral("expiresAtMs")).toInteger();
            const auto created = dispatch(m_host, {
                {QStringLiteral("command"), QStringLiteral("create")},
                {QStringLiteral("display_name"), QStringLiteral("Native host")},
                {QStringLiteral("expires_at_ms"), expires},
                {QStringLiteral("relay_session_id"), m_session},
                {QStringLiteral("relay_host_capability"), relay.value(QStringLiteral("hostCapability"))},
                {QStringLiteral("relay_guest_capability"), relay.value(QStringLiteral("guestCapability"))},
            });
            if (created.isEmpty()) return;
            const auto joined = dispatch(m_guest, {
                {QStringLiteral("command"), QStringLiteral("join")},
                {QStringLiteral("display_name"), QStringLiteral("Native guest")},
                {QStringLiteral("relay_session_id"), m_session},
                {QStringLiteral("fragment"), created.value(QStringLiteral("fragment"))},
                {QStringLiteral("now_ms"), QDateTime::currentMSecsSinceEpoch()},
            });
            if (joined.isEmpty()) return;
            m_joinFrame = joined.value(QStringLiteral("outbound")).toArray().first().toObject();
            open(m_hostSocket, relay.value(QStringLiteral("hostCapability")).toString());
            open(m_guestSocket, joined.value(QStringLiteral("relayCapability")).toString());
        });
    }

private:
    QJsonObject dispatch(PartyCoreBridge &core, const QJsonObject &command)
    {
        QString error;
        const auto response = core.dispatch(command, &error);
        if (!response.value(QStringLiteral("ok")).toBool()) {
            fail(error);
            return {};
        }
        return response.value(QStringLiteral("value")).toObject();
    }

    void open(WebSocketClient &socket, const QString &capability)
    {
        QUrl url(m_base);
        url.setScheme(url.scheme() == QStringLiteral("https") ? QStringLiteral("wss") : QStringLiteral("ws"));
        url.setPath(QStringLiteral("/v1/party-sessions/%1/relay").arg(m_session));
        url.setQuery(QStringLiteral("protocolVersion=2"));
        socket.open(url, capability);
    }

    void startJoin()
    {
        if (m_joinSent || !m_hostSocket.connected() || !m_guestSocket.connected()) return;
        m_joinSent = true;
        m_guestSocket.sendBinary(QJsonDocument(m_joinFrame).toJson(QJsonDocument::Compact));
    }

    void hostReceived(const QByteArray &payload)
    {
        const auto frame = QJsonDocument::fromJson(payload).object();
        const auto value = dispatch(m_host, {{QStringLiteral("command"), QStringLiteral("receive")},
                                             {QStringLiteral("frame"), frame},
                                             {QStringLiteral("received_at_ms"), QDateTime::currentMSecsSinceEpoch()}});
        for (const auto &outbound : value.value(QStringLiteral("outbound")).toArray())
            m_hostSocket.sendBinary(QJsonDocument(outbound.toObject()).toJson(QJsonDocument::Compact));
    }

    void guestReceived(const QByteArray &payload)
    {
        const auto frame = QJsonDocument::fromJson(payload).object();
        const auto value = dispatch(m_guest, {{QStringLiteral("command"), QStringLiteral("receive")},
                                              {QStringLiteral("frame"), frame}});
        if (value.value(QStringLiteral("event")).toObject().value(QStringLiteral("body")).toObject()
                .value(QStringLiteral("type")).toString() == QStringLiteral("clock_pong")) {
            qInfo("native host and guest synchronized an encrypted clock sample through the opaque relay");
            QCoreApplication::exit(0);
            return;
        }
        if (!m_clockSent && value.value(QStringLiteral("state")).toObject()
                .value(QStringLiteral("participants")).toArray().size() == 2) {
            m_clockSent = true;
            const auto ping = dispatch(m_guest, {
                {QStringLiteral("command"), QStringLiteral("clock_ping")},
                {QStringLiteral("nonce"), 1},
                {QStringLiteral("client_send_ms"), QDateTime::currentMSecsSinceEpoch()},
            });
            for (const auto &outbound : ping.value(QStringLiteral("outbound")).toArray())
                m_guestSocket.sendBinary(QJsonDocument(outbound.toObject()).toJson(QJsonDocument::Compact));
        }
    }

    void fail(const QString &message)
    {
        qCritical().noquote() << message;
        QCoreApplication::exit(1);
    }

    QNetworkAccessManager m_network;
    PartyCoreBridge m_host;
    PartyCoreBridge m_guest;
    WebSocketClient m_hostSocket;
    WebSocketClient m_guestSocket;
    QString m_base;
    QString m_session;
    QJsonObject m_joinFrame;
    bool m_joinSent = false;
    bool m_clockSent = false;
};

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    PartyTransportTest test;
    QTimer timeout;
    timeout.setSingleShot(true);
    QObject::connect(&timeout, &QTimer::timeout, &app, [] {
        qCritical("party transport test timed out");
        QCoreApplication::exit(1);
    });
    timeout.start(10'000);
    QTimer::singleShot(0, &test, &PartyTransportTest::start);
    return app.exec();
}

#include "partytransporttest.moc"
