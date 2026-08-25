#include "discordpresence.h"

#include "debuglog.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonParseError>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcessEnvironment>
#include <QSettings>
#include <QtEndian>
#include <algorithm>

namespace {
constexpr auto defaultApplicationId = "1528095256820842606";
constexpr quint32 maximumFrameSize = 1024 * 1024;
constexpr auto discordTokenRelay = "https://colorful.valerie.sh/v1/discord/rpc-token";

#if !defined(Q_OS_WIN)
QString discordRuntimeDirectory()
{
    const auto environment = QProcessEnvironment::systemEnvironment();
    for (const auto &name : {QStringLiteral("XDG_RUNTIME_DIR"), QStringLiteral("TMPDIR"),
                             QStringLiteral("TMP"), QStringLiteral("TEMP")}) {
        const auto value = environment.value(name);
        if (!value.isEmpty()) return value;
    }
    return QStringLiteral("/tmp");
}
#endif
}

DiscordPresence::DiscordPresence(QObject *parent)
    : QObject(parent)
{
    QSettings settings;
    m_applicationId = QString::fromLatin1(defaultApplicationId);
    settings.remove(QStringLiteral("discord/applicationId"));
    const auto currentProcessId = QCoreApplication::applicationPid();
    const auto previousProcessId = settings.value(QStringLiteral("discord/lastRpcProcessId"), 0).toLongLong();
    if (previousProcessId > 0 && previousProcessId != currentProcessId) {
        m_staleProcessId = previousProcessId;
    }
    settings.setValue(QStringLiteral("discord/lastRpcProcessId"), currentProcessId);
    m_enabled = !qEnvironmentVariableIsSet("COLORFUL_DISABLE_DISCORD_RPC");
    if (!m_enabled) return;
    m_reconnectTimer.setSingleShot(true);
    m_reconnectTimer.setInterval(15000);
    connect(&m_reconnectTimer, &QTimer::timeout, this, &DiscordPresence::connectToDiscord);
    connect(&m_socket, &QLocalSocket::connected, this, &DiscordPresence::handleConnected);
    connect(&m_socket, &QLocalSocket::disconnected, this, &DiscordPresence::handleDisconnected);
    connect(&m_socket, &QLocalSocket::readyRead, this, &DiscordPresence::handleReadyRead);
    connect(&m_socket, &QLocalSocket::errorOccurred, this, [this](QLocalSocket::LocalSocketError) {
        if (m_shuttingDown || m_socket.state() != QLocalSocket::UnconnectedState) return;
        ++m_candidateIndex;
        if (m_candidateIndex >= m_candidates.size() && !m_unavailableLogged) {
            m_unavailableLogged = true;
            DebugLog::write(u"discord",
                            QStringLiteral("RPC unavailable after %1 candidates: %2")
                                .arg(m_candidates.size())
                                .arg(m_socket.errorString()));
        }
        QTimer::singleShot(0, this, &DiscordPresence::connectToDiscord);
    });
    connectToDiscord();
}

DiscordPresence::~DiscordPresence()
{
    shutdown();
}

void DiscordPresence::shutdown()
{
    if (m_shuttingDown) return;
    m_shuttingDown = true;
    bool cleared = false;
    if (m_socket.state() == QLocalSocket::ConnectedState && m_ready) {
        clearActivityForProcess(QCoreApplication::applicationPid());
        cleared = flushActivity(500);
    }
    if (cleared) {
        QSettings settings;
        settings.remove(QStringLiteral("discord/lastRpcProcessId"));
        settings.sync();
    }
    m_hasDesiredActivity = false;
    m_desiredActivity = {};
    m_socket.abort();
}

void DiscordPresence::update(const QString &title,
                             const QString &artist,
                             const QString &album,
                             const QString &artworkUrl,
                             qint64 positionMs,
                             qint64 durationMs,
                             bool playing)
{
    if (title.trimmed().isEmpty()) {
        clear();
        return;
    }

    QJsonObject activity{
        // Discord's native party/invite controls are only exposed for a
        // joinable game activity. Keep the normal Listening presence when no
        // Colorful party is being hosted.
        {QStringLiteral("type"), m_partyJoinEnabled ? 0 : 2},
        {QStringLiteral("details"), title.left(128)},
        {QStringLiteral("state"), (playing ? artist
                                            : artist.isEmpty() ? QStringLiteral("Paused")
                                                               : artist + QStringLiteral(" · Paused")).left(128)},
        {QStringLiteral("instance"), false},
    };
    if (playing) {
        const auto nowSeconds = QDateTime::currentSecsSinceEpoch();
        const auto startSeconds = nowSeconds - std::max<qint64>(0, positionMs) / 1000;
        QJsonObject timestamps{{QStringLiteral("start"), startSeconds}};
        if (durationMs > 0) timestamps.insert(QStringLiteral("end"), startSeconds + durationMs / 1000);
        activity.insert(QStringLiteral("timestamps"), timestamps);
    }

    QJsonObject assets;
    if (artworkUrl.startsWith(QStringLiteral("https://"), Qt::CaseInsensitive)) {
        assets.insert(QStringLiteral("large_image"), artworkUrl);
        assets.insert(QStringLiteral("large_text"), album.isEmpty() ? title : album.left(128));
    }
    if (!assets.isEmpty()) activity.insert(QStringLiteral("assets"), assets);

    if (m_partyJoinEnabled && !m_partyId.isEmpty() && !m_partyJoinSecret.isEmpty()) {
        activity.insert(QStringLiteral("party"), QJsonObject{
            {QStringLiteral("id"), m_partyId},
            {QStringLiteral("size"), QJsonArray{m_partyCurrentSize, m_partyMaximumSize}},
        });
        activity.insert(QStringLiteral("secrets"), QJsonObject{
            {QStringLiteral("join"), m_partyJoinSecret},
        });
    }

    m_desiredActivity = activity;
    m_hasDesiredActivity = true;
    publishDesiredActivity();
}

void DiscordPresence::setParty(const QString &partyId, int currentSize, int maximumSize,
                               const QString &joinSecret, bool joinEnabled)
{
    // Discord limits activity secrets to 128 bytes. The compact party secret
    // deliberately excludes the public landing-page URL so it remains inside
    // that limit and never exposes it in presence text.
    const bool usable = joinEnabled && !partyId.isEmpty() && !joinSecret.isEmpty()
        && joinSecret.toUtf8().size() <= 128;
    const auto normalizedCurrentSize = std::max(1, currentSize);
    const auto normalizedMaximumSize = std::max(normalizedCurrentSize, maximumSize);
    if (m_partyId == partyId && m_partyJoinSecret == joinSecret
        && m_partyCurrentSize == normalizedCurrentSize && m_partyMaximumSize == normalizedMaximumSize
        && m_partyJoinEnabled == usable) return;
    m_partyId = partyId;
    m_partyJoinSecret = joinSecret;
    m_partyCurrentSize = normalizedCurrentSize;
    m_partyMaximumSize = normalizedMaximumSize;
    m_partyJoinEnabled = usable;
    if (joinEnabled && !usable) {
        DebugLog::write(u"discord", QStringLiteral("party invite unavailable: invalid or oversized join secret"));
    }
    if (m_partyJoinEnabled) beginAuthorization();
    publishDesiredActivity();
}

void DiscordPresence::setPartyInvitesEnabled(bool enabled)
{
    if (m_partyInvitesEnabled == enabled) return;
    m_partyInvitesEnabled = enabled;
    if (enabled) beginAuthorization();
}

void DiscordPresence::respondToJoinRequest(const QString &userId, bool accepted)
{
    if (!m_authenticated || userId.isEmpty()) return;
    writeFrame(Opcode::Frame, {
        {QStringLiteral("cmd"), accepted ? QStringLiteral("SEND_ACTIVITY_JOIN_INVITE")
                                          : QStringLiteral("CLOSE_ACTIVITY_REQUEST")},
        {QStringLiteral("args"), QJsonObject{{QStringLiteral("user_id"), userId}}},
        {QStringLiteral("nonce"), QString::number(++m_nonce)},
    });
}

void DiscordPresence::clear()
{
    if (!m_hasDesiredActivity && m_desiredActivity.isEmpty()) return;
    m_hasDesiredActivity = false;
    m_desiredActivity = {};
    publishDesiredActivity();
}

void DiscordPresence::connectToDiscord()
{
    if (!m_enabled || m_shuttingDown || m_socket.state() != QLocalSocket::UnconnectedState) return;

    if (!m_candidates.isEmpty() && m_candidateIndex >= m_candidates.size()) {
        m_candidates.clear();
        m_candidateIndex = 0;
        scheduleReconnect();
        return;
    }
    if (m_candidates.isEmpty()) {
        m_candidates.clear();
        m_candidateIndex = 0;
        for (int index = 0; index < 10; ++index) {
#if defined(Q_OS_WIN)
            // QLocalSocket adds Windows' \\.\pipe\ namespace itself. Passing
            // Discord's documented full \\?\pipe\ path would make Qt prepend
            // a second, incompatible pipe namespace.
            m_candidates.append(QStringLiteral("discord-ipc-%1").arg(index));
#else
            const QDir runtime(discordRuntimeDirectory());
            const auto path = runtime.filePath(QStringLiteral("discord-ipc-%1").arg(index));
            if (QFileInfo::exists(path)) m_candidates.append(path);
#endif
        }
        if (m_candidates.isEmpty()) {
            scheduleReconnect();
            return;
        }
    }

    m_socket.connectToServer(m_candidates.at(m_candidateIndex));
}

void DiscordPresence::handleConnected()
{
    m_unavailableLogged = false;
    DebugLog::write(u"discord",
                    QStringLiteral("RPC pipe connected candidate=%1").arg(m_candidateIndex));
    m_ready = false;
    m_readBuffer.clear();
    writeFrame(Opcode::Handshake, {
        {QStringLiteral("v"), 1},
        {QStringLiteral("client_id"), m_applicationId},
    });
}

void DiscordPresence::handleDisconnected()
{
    m_ready = false;
    m_authenticated = false;
    m_authorizing = false;
    m_authorizeNonce.clear();
    m_authenticateNonce.clear();
    m_readBuffer.clear();
    if (!m_shuttingDown) scheduleReconnect();
}

void DiscordPresence::handleReadyRead()
{
    m_readBuffer.append(m_socket.readAll());
    while (m_readBuffer.size() >= 8) {
        const auto *header = reinterpret_cast<const uchar *>(m_readBuffer.constData());
        const auto opcode = static_cast<Opcode>(qFromLittleEndian<quint32>(header));
        const auto length = qFromLittleEndian<quint32>(header + 4);
        if (length > maximumFrameSize) {
            m_socket.abort();
            return;
        }
        if (m_readBuffer.size() < 8 + static_cast<qsizetype>(length)) return;
        const auto payload = m_readBuffer.mid(8, length);
        m_readBuffer.remove(0, 8 + length);
        handleFrame(opcode, payload);
    }
}

void DiscordPresence::handleFrame(Opcode opcode, const QByteArray &payload)
{
    if (opcode == Opcode::Ping) {
        QJsonParseError error;
        const auto document = QJsonDocument::fromJson(payload, &error);
        if (error.error == QJsonParseError::NoError && document.isObject()) {
            writeFrame(Opcode::Pong, document.object());
        }
        return;
    }
    if (opcode == Opcode::Close) {
        m_socket.abort();
        return;
    }
    if (opcode != Opcode::Frame) return;

    QJsonParseError error;
    const auto document = QJsonDocument::fromJson(payload, &error);
    if (error.error != QJsonParseError::NoError || !document.isObject()) return;
    const auto message = document.object();
    const auto command = message.value(QStringLiteral("cmd")).toString();
    const auto event = message.value(QStringLiteral("evt")).toString();
    if (command == QStringLiteral("DISPATCH") && event == QStringLiteral("READY")) {
        m_ready = true;
        DebugLog::write(u"discord", QStringLiteral("RPC ready"));
        if (m_staleProcessId > 0) {
            clearActivityForProcess(m_staleProcessId);
            m_staleProcessId = 0;
        }
        publishDesiredActivity();
        beginAuthorization();
        return;
    }
    if (command == QStringLiteral("AUTHORIZE")
        && message.value(QStringLiteral("nonce")).toString() == m_authorizeNonce) {
        const auto code = message.value(QStringLiteral("data")).toObject()
                              .value(QStringLiteral("code")).toString();
        if (code.isEmpty()) {
            m_authorizing = false;
            DebugLog::write(u"discord", QStringLiteral("RPC authorization returned no code"));
        } else {
            exchangeAuthorizationCode(code);
        }
        return;
    }
    if (command == QStringLiteral("AUTHENTICATE")
        && message.value(QStringLiteral("nonce")).toString() == m_authenticateNonce) {
        m_authenticated = true;
        m_authorizing = false;
        DebugLog::write(u"discord", QStringLiteral("RPC party authorization complete"));
        subscribe(QStringLiteral("ACTIVITY_JOIN_REQUEST"));
        subscribe(QStringLiteral("ACTIVITY_JOIN"));
        return;
    }
    if (command == QStringLiteral("DISPATCH") && event == QStringLiteral("ACTIVITY_JOIN_REQUEST")) {
        const auto data = message.value(QStringLiteral("data")).toObject();
        const auto user = data.value(QStringLiteral("user")).toObject();
        const auto userId = user.value(QStringLiteral("id")).toString();
        if (userId.isEmpty()) return;
        QVariantMap request;
        request.insert(QStringLiteral("userId"), userId);
        request.insert(QStringLiteral("username"), user.value(QStringLiteral("username")).toString());
        request.insert(QStringLiteral("globalName"), user.value(QStringLiteral("global_name")).toString());
        request.insert(QStringLiteral("avatar"), user.value(QStringLiteral("avatar")).toString());
        emit activityJoinRequested(request);
        return;
    }
    if (command == QStringLiteral("DISPATCH") && event == QStringLiteral("ACTIVITY_JOIN")) {
        const auto secret = message.value(QStringLiteral("data")).toObject()
                                .value(QStringLiteral("secret")).toString();
        if (!secret.isEmpty()) emit activityJoin(secret);
        return;
    }
    if (event == QStringLiteral("ERROR")) {
        const auto detail = message.value(QStringLiteral("data")).toObject()
                                .value(QStringLiteral("message")).toString();
        DebugLog::write(u"discord", QStringLiteral("RPC error cmd=%1: %2").arg(command, detail));
        if (message.value(QStringLiteral("nonce")).toString() == m_authorizeNonce
            || message.value(QStringLiteral("nonce")).toString() == m_authenticateNonce)
            m_authorizing = false;
    }
}

void DiscordPresence::beginAuthorization()
{
    if ((!m_partyJoinEnabled && !m_partyInvitesEnabled) || !m_ready || m_authenticated || m_authorizing
        || m_socket.state() != QLocalSocket::ConnectedState) return;
    m_authorizing = true;
    m_authorizeNonce = QStringLiteral("authorize-%1").arg(++m_nonce);
    writeFrame(Opcode::Frame, {
        {QStringLiteral("cmd"), QStringLiteral("AUTHORIZE")},
        {QStringLiteral("args"), QJsonObject{
            {QStringLiteral("client_id"), m_applicationId},
            {QStringLiteral("scopes"), QJsonArray{QStringLiteral("rpc"), QStringLiteral("identify")}},
        }},
        {QStringLiteral("nonce"), m_authorizeNonce},
    });
}

void DiscordPresence::exchangeAuthorizationCode(const QString &code)
{
    QNetworkRequest request(QUrl(QString::fromLatin1(discordTokenRelay)));
    request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    auto *reply = m_network.post(request, QJsonDocument(QJsonObject{{QStringLiteral("code"), code}})
                                              .toJson(QJsonDocument::Compact));
    QTimer::singleShot(15'000, reply, [reply] { if (reply->isRunning()) reply->abort(); });
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        const auto body = reply->readAll();
        const auto networkError = reply->error();
        reply->deleteLater();
        QJsonParseError error;
        const auto document = QJsonDocument::fromJson(body, &error);
        const auto accessToken = document.object().value(QStringLiteral("accessToken")).toString();
        if (networkError != QNetworkReply::NoError || error.error != QJsonParseError::NoError
            || accessToken.isEmpty() || !m_ready) {
            m_authorizing = false;
            DebugLog::write(u"discord", QStringLiteral("RPC token exchange failed"));
            return;
        }
        m_authenticateNonce = QStringLiteral("authenticate-%1").arg(++m_nonce);
        writeFrame(Opcode::Frame, {
            {QStringLiteral("cmd"), QStringLiteral("AUTHENTICATE")},
            {QStringLiteral("args"), QJsonObject{{QStringLiteral("access_token"), accessToken}}},
            {QStringLiteral("nonce"), m_authenticateNonce},
        });
    });
}

void DiscordPresence::subscribe(const QString &event)
{
    writeFrame(Opcode::Frame, {
        {QStringLiteral("cmd"), QStringLiteral("SUBSCRIBE")},
        {QStringLiteral("evt"), event},
        {QStringLiteral("nonce"), QString::number(++m_nonce)},
    });
}

void DiscordPresence::publishDesiredActivity()
{
    if (!m_ready || m_socket.state() != QLocalSocket::ConnectedState) return;
    QJsonObject arguments{{QStringLiteral("pid"), QCoreApplication::applicationPid()}};
    if (m_hasDesiredActivity) arguments.insert(QStringLiteral("activity"), m_desiredActivity);
    writeFrame(Opcode::Frame, {
        {QStringLiteral("cmd"), QStringLiteral("SET_ACTIVITY")},
        {QStringLiteral("args"), arguments},
        {QStringLiteral("nonce"), QString::number(++m_nonce)},
    });
}

void DiscordPresence::clearActivityForProcess(qint64 processId)
{
    if (!m_ready || m_socket.state() != QLocalSocket::ConnectedState || processId <= 0) return;
    writeFrame(Opcode::Frame, {
        {QStringLiteral("cmd"), QStringLiteral("SET_ACTIVITY")},
        {QStringLiteral("args"), QJsonObject{
            {QStringLiteral("pid"), processId},
            {QStringLiteral("activity"), QJsonValue(QJsonValue::Null)},
        }},
        {QStringLiteral("nonce"), QString::number(++m_nonce)},
    });
}

bool DiscordPresence::flushActivity(int timeoutMs)
{
    if (!m_socket.flush()) return false;
    if (m_socket.bytesToWrite() > 0 && !m_socket.waitForBytesWritten(timeoutMs)) return false;
    // Discord acknowledges SET_ACTIVITY. Waiting for that response prevents
    // process teardown from racing the clear frame on a busy IPC connection.
    if (!m_socket.waitForReadyRead(timeoutMs)) return false;
    handleReadyRead();
    return true;
}

void DiscordPresence::writeFrame(Opcode opcode, const QJsonObject &payload)
{
    if (m_socket.state() != QLocalSocket::ConnectedState) return;
    const auto json = QJsonDocument(payload).toJson(QJsonDocument::Compact);
    QByteArray frame(8, Qt::Uninitialized);
    qToLittleEndian(static_cast<quint32>(opcode), reinterpret_cast<uchar *>(frame.data()));
    qToLittleEndian(static_cast<quint32>(json.size()), reinterpret_cast<uchar *>(frame.data() + 4));
    frame.append(json);
    m_socket.write(frame);
}

void DiscordPresence::scheduleReconnect()
{
    if (!m_shuttingDown && !m_reconnectTimer.isActive()) m_reconnectTimer.start();
}
