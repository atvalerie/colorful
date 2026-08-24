#include "discordpresence.h"

#include "debuglog.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonArray>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSettings>
#include <QUrl>
#include <QtEndian>
#include <algorithm>

namespace {
constexpr auto defaultApplicationId = "1528095256820842606";
constexpr quint32 maximumFrameSize = 1024 * 1024;

QString validHttpUrl(const QString &value)
{
    const QUrl url(value.trimmed());
    if (!url.isValid() || url.host().isEmpty()
        || (url.scheme().compare(QStringLiteral("https"), Qt::CaseInsensitive) != 0
            && url.scheme().compare(QStringLiteral("http"), Qt::CaseInsensitive) != 0))
        return {};
    return url.toString(QUrl::FullyEncoded);
}

QString validJoinPartyUrl(const QString &value)
{
    const QUrl url(value.trimmed());
    if (!url.isValid() || url.scheme() != QStringLiteral("https")
        || url.host() != QStringLiteral("colorful.valerie.sh")
        || url.path() != QStringLiteral("/discord/join")
        || !url.userInfo().isEmpty() || url.port() != -1
        || !url.query(QUrl::FullyEncoded).isEmpty()) return {};
    static const QRegularExpression ticketPattern(
        QStringLiteral("^v1\\.[A-Za-z0-9_-]{43}\\.[A-Za-z0-9_-]{43}$"));
    const auto fragment = url.fragment(QUrl::FullyEncoded);
    if (!ticketPattern.match(fragment).hasMatch()) return {};
    const auto fields = fragment.split(QLatin1Char('.'));
    for (int index = 1; index < fields.size(); ++index) {
        const auto bytes = QByteArray::fromBase64(fields.at(index).toLatin1(), QByteArray::Base64UrlEncoding);
        if (bytes.size() != 32
            || QString::fromLatin1(bytes.toBase64(QByteArray::Base64UrlEncoding
                                                   | QByteArray::OmitTrailingEquals)) != fields.at(index))
            return {};
    }
    return url.toString(QUrl::FullyEncoded);
}

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
    m_reconnectTimer.setSingleShot(true);
    m_reconnectTimer.setInterval(15000);
    connect(&m_reconnectTimer, &QTimer::timeout, this, &DiscordPresence::connectToDiscord);
    connect(&m_socket, &QLocalSocket::connected, this, &DiscordPresence::handleConnected);
    connect(&m_socket, &QLocalSocket::disconnected, this, &DiscordPresence::handleDisconnected);
    connect(&m_socket, &QLocalSocket::readyRead, this, &DiscordPresence::handleReadyRead);
    connect(&m_socket, &QLocalSocket::errorOccurred, this, [this](QLocalSocket::LocalSocketError) {
        if (!m_enabled || m_shuttingDown || m_socket.state() != QLocalSocket::UnconnectedState) return;
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
    if (m_enabled) connectToDiscord();
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
    m_trackUrl.clear();
    m_partyId.clear();
    m_partySize = 0;
    m_joinPartyUrl.clear();
    m_socket.abort();
}

void DiscordPresence::setEnabled(bool enabled)
{
    const auto effective = enabled && !qEnvironmentVariableIsSet("COLORFUL_DISABLE_DISCORD_RPC");
    if (m_enabled == effective) return;
    if (!effective) {
        m_reconnectTimer.stop();
        if (m_socket.state() == QLocalSocket::ConnectedState && m_ready) {
            clearActivityForProcess(QCoreApplication::applicationPid());
            flushActivity(500);
        }
        m_hasDesiredActivity = false;
        m_desiredActivity = {};
        m_trackUrl.clear();
        m_partyId.clear();
        m_partySize = 0;
        m_joinPartyUrl.clear();
        m_ready = false;
        m_socket.abort();
        m_enabled = false;
        return;
    }
    m_enabled = true;
    m_shuttingDown = false;
    m_candidateIndex = 0;
    m_candidates.clear();
    m_unavailableLogged = false;
    connectToDiscord();
}

void DiscordPresence::setTrackButtonEnabled(bool enabled)
{
    if (m_trackButtonEnabled == enabled) return;
    m_trackButtonEnabled = enabled;
    if (!m_hasDesiredActivity) return;
    rebuildButtons();
    publishDesiredActivity();
}

void DiscordPresence::rebuildButtons()
{
    m_desiredActivity.remove(QStringLiteral("buttons"));
    QJsonArray buttons;
    const auto track = validHttpUrl(m_trackUrl);
    if (m_trackButtonEnabled && !track.isEmpty())
        buttons.append(QJsonObject{{QStringLiteral("label"), QStringLiteral("View Track")},
                                   {QStringLiteral("url"), track}});
    const auto join = validJoinPartyUrl(m_joinPartyUrl);
    if (!m_partyId.isEmpty() && !join.isEmpty())
        buttons.append(QJsonObject{{QStringLiteral("label"), QStringLiteral("Join Party")},
                                   {QStringLiteral("url"), join}});
    if (!buttons.isEmpty()) m_desiredActivity.insert(QStringLiteral("buttons"), buttons);
}

void DiscordPresence::update(const QString &title,
                             const QString &artist,
                             const QString &album,
                             const QString &artworkUrl,
                             qint64 positionMs,
                             qint64 durationMs,
                             bool playing,
                             const QString &trackUrl,
                             const QString &partyId,
                             int partySize,
                             const QString &joinPartyUrl)
{
    if (!m_enabled || title.trimmed().isEmpty()) {
        clear();
        return;
    }

    m_trackUrl = validHttpUrl(trackUrl);
    m_partyId = partyId.trimmed();
    m_partySize = std::clamp(partySize, 0, 64);
    m_joinPartyUrl = joinPartyUrl;
    m_desiredActivity = buildActivity(title, artist, album, artworkUrl, positionMs,
                                      durationMs, playing, m_trackUrl,
                                      m_trackButtonEnabled, m_partyId, m_partySize,
                                      m_joinPartyUrl);
    m_hasDesiredActivity = true;
    publishDesiredActivity();
}

QJsonObject DiscordPresence::buildActivity(const QString &title,
                                           const QString &artist,
                                           const QString &album,
                                           const QString &artworkUrl,
                                           qint64 positionMs,
                                           qint64 durationMs,
                                           bool playing,
                                           const QString &trackUrl,
                                           bool trackButtonEnabled,
                                           const QString &partyId,
                                           int partySize,
                                           const QString &joinPartyUrl)
{
    QJsonObject activity{
        {QStringLiteral("type"), 2}, // Listening
        {QStringLiteral("details"), title.left(128)},
        {QStringLiteral("state"), (playing ? artist
                                            : artist.isEmpty() ? QStringLiteral("Paused")
                                                               : artist + QStringLiteral(" · Paused")).left(128)},
        {QStringLiteral("instance"), !partyId.trimmed().isEmpty()},
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

    const auto validTrackUrl = validHttpUrl(trackUrl);
    QJsonArray buttons;
    if (trackButtonEnabled && !validTrackUrl.isEmpty())
        buttons.append(QJsonObject{{QStringLiteral("label"), QStringLiteral("View Track")},
                                   {QStringLiteral("url"), validTrackUrl}});
    const auto validJoinUrl = validJoinPartyUrl(joinPartyUrl);
    if (!partyId.trimmed().isEmpty() && !validJoinUrl.isEmpty())
        buttons.append(QJsonObject{{QStringLiteral("label"), QStringLiteral("Join Party")},
                                   {QStringLiteral("url"), validJoinUrl}});
    if (!buttons.isEmpty()) activity.insert(QStringLiteral("buttons"), buttons);
    if (!partyId.trimmed().isEmpty()) {
        activity.insert(QStringLiteral("party"), QJsonObject{
            {QStringLiteral("id"), partyId.left(128)},
            {QStringLiteral("size"), QJsonArray{qBound(1, partySize, 64), 64}},
        });
    }
    return activity;
}

void DiscordPresence::clear()
{
    if (!m_hasDesiredActivity && m_desiredActivity.isEmpty()) return;
    m_hasDesiredActivity = false;
    m_desiredActivity = {};
    m_trackUrl.clear();
    m_partyId.clear();
    m_partySize = 0;
    m_joinPartyUrl.clear();
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
    if (message.value(QStringLiteral("evt")).toString() == QStringLiteral("ERROR")
        || message.value(QStringLiteral("cmd")).toString() == QStringLiteral("ERROR")) {
        const auto data = message.value(QStringLiteral("data")).toObject();
        const auto code = data.value(QStringLiteral("code")).isUndefined()
            ? message.value(QStringLiteral("code")).toVariant().toString()
            : data.value(QStringLiteral("code")).toVariant().toString();
        auto detail = data.value(QStringLiteral("message")).toString(
            message.value(QStringLiteral("message")).toString()).left(256);
        // Discord normally reports a short validation message, but redact any
        // URL before writing diagnostics so rejected activity payloads cannot
        // leak a track link or other user-provided secret.
        detail.replace(QRegularExpression(QStringLiteral(R"(https?://[^\s"'<>]+)")),
                       QStringLiteral("[url]"));
        DebugLog::write(u"discord", QStringLiteral("RPC error cmd=%1 nonce=%2 code=%3 message=%4")
                                        .arg(message.value(QStringLiteral("cmd")).toString(),
                                             message.value(QStringLiteral("nonce")).toString(),
                                             code, detail));
        return;
    }
    if (message.value(QStringLiteral("cmd")).toString() == QStringLiteral("DISPATCH")
        && message.value(QStringLiteral("evt")).toString() == QStringLiteral("READY")) {
        m_ready = true;
        DebugLog::write(u"discord", QStringLiteral("RPC ready"));
        if (m_staleProcessId > 0) {
            clearActivityForProcess(m_staleProcessId);
            m_staleProcessId = 0;
        }
        publishDesiredActivity();
    }
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
    if (m_enabled && !m_shuttingDown && !m_reconnectTimer.isActive()) m_reconnectTimer.start();
}
