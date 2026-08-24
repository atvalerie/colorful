#include "partyclient.h"

#include "backend.h"
#include <QDateTime>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QUrl>
#include <cstring>
#include <cmath>

namespace {
constexpr int PartyProtocolVersion = 2;
constexpr qsizetype MaxPendingPartyBytes = 4 * 1024 * 1024;
constexpr qsizetype MaxPendingPartyFrames = 512;
constexpr qint64 PublicJoinTicketLifetimeMs = 90'000;
constexpr qint64 PublicJoinTicketRefreshLeadMs = 30'000;
constexpr int PublicJoinTicketRetryMs = 15'000;

QString canonicalPublicJoinTicket(const QString &fragment)
{
    static const QRegularExpression valid(QStringLiteral("^v1\\.[A-Za-z0-9_-]{43}\\.[A-Za-z0-9_-]{43}$"));
    if (!valid.match(fragment).hasMatch()) return {};
    const auto parts = fragment.split(QLatin1Char('.'));
    for (int i = 1; i < parts.size(); ++i) {
        const auto bytes = QByteArray::fromBase64(parts.at(i).toLatin1(), QByteArray::Base64UrlEncoding);
        if (bytes.size() != 32
            || QString::fromLatin1(bytes.toBase64(QByteArray::Base64UrlEncoding
                                                   | QByteArray::OmitTrailingEquals)) != parts.at(i))
            return {};
    }
    return fragment;
}

QString publicJoinTicketLookup(const QString &ticket)
{
    const auto parts = ticket.split(QLatin1Char('.'));
    return parts.size() == 3 ? parts.at(1) : QString{};
}

bool isPublicPartyRelay(const QString &baseUrl)
{
    const QUrl url(baseUrl);
    return url.isValid() && url.scheme() == QStringLiteral("https")
        && url.host() == QStringLiteral("colorful.valerie.sh")
        && url.port() == -1 && url.userInfo().isEmpty()
        && (url.path().isEmpty() || url.path() == QStringLiteral("/"))
        && url.query().isEmpty() && url.fragment().isEmpty();
}

QString partySessionFromUrl(const QUrl &url)
{
    QString session;
    if (url.scheme() == QStringLiteral("colorful") && url.host() == QStringLiteral("party")) {
        const auto path = url.path();
        if (path.size() <= 1 || !path.startsWith('/')) return {};
        session = path.mid(1);
    } else if (url.scheme() == QStringLiteral("https")
               && url.host() == QStringLiteral("colorful.valerie.sh")) {
        constexpr auto prefix = "/party/";
        const auto path = url.path();
        if (!path.startsWith(prefix) || path.size() <= qsizetype(std::strlen(prefix))) return {};
        session = path.mid(qsizetype(std::strlen(prefix)));
    }
    static const QRegularExpression valid(QStringLiteral("^[A-Za-z0-9_-]{8,64}$"));
    return valid.match(session).hasMatch() ? session : QString{};
}

// Playback is emitted by more than one protocol shape (live events and state
// snapshots). Accept either wire spelling at that boundary so a producer-side
// serialization change cannot silently turn into an empty track id.
QJsonValue partyField(const QJsonObject &object, const QString &camelCase,
                      const QString &snakeCase = {})
{
    if (object.contains(camelCase)) return object.value(camelCase);
    return snakeCase.isEmpty() ? QJsonValue{} : object.value(snakeCase);
}
}

PartyClient::PartyClient(Backend *backend, QObject *parent)
    : QObject(parent), m_backend(backend), m_socket(this)
{
    m_monotonicClock.start();
    m_clockEpochMs = QDateTime::currentMSecsSinceEpoch();
    connect(&m_socket, &WebSocketClient::connectedChanged, this, [this](bool connected) {
        setStatus(connected ? QStringLiteral("Party connected") : QStringLiteral("Party disconnected"));
        if (connected) {
            if (m_everConnected || m_needsResync) {
                m_pendingFrames.clear();
                m_pendingFrameBytes = 0;
                m_needsResync = false;
                dispatch({{QStringLiteral("command"), m_role == QStringLiteral("host")
                    ? QStringLiteral("host_snapshot") : QStringLiteral("resync")}});
            } else {
                flushOutbound();
            }
            if (m_role != QStringLiteral("host")) {
                sendClockPing();
            }
            m_everConnected = true;
        } else {
            m_pendingFrames.clear();
            m_pendingFrameBytes = 0;
        }
        emit stateChanged();
    });
    connect(&m_socket, &WebSocketClient::binaryMessage, this, &PartyClient::receiveFrame);
    connect(&m_socket, &WebSocketClient::failed, this, [this](const QString &message) {
        setStatus(QStringLiteral("Party connection failed: %1").arg(message));
        if (!m_active) emit notification(m_status, QStringLiteral("error"));
    });
    m_hostClock.setInterval(1000);
    connect(&m_hostClock, &QTimer::timeout, this, &PartyClient::publishPlayback);
    m_clockSampler.setInterval(2000);
    connect(&m_clockSampler, &QTimer::timeout, this, &PartyClient::sendClockPing);
    m_driftController.setInterval(250);
    connect(&m_driftController, &QTimer::timeout, this, &PartyClient::correctPlayback);
    m_publicTicketTimer.setSingleShot(true);
    connect(&m_publicTicketTimer, &QTimer::timeout, this, &PartyClient::refreshPublicJoinTicket);
    connect(backend, &Backend::discordSettingsChanged, this, [this] {
        refreshPublicJoinTicket();
        publishDiscordPartyState();
    });
    connect(backend, &Backend::currentTrackChanged, this, [this] {
        if (m_role == QStringLiteral("host") && !m_applyingRemote) {
            ++m_generation;
            publishCurrentTrack();
        }
    });
    connect(backend, &Backend::queueChanged, this, [this] {
        if (m_role == QStringLiteral("host")) publishQueue();
    });
    connect(backend, &Backend::playbackChanged, this, [this] {
        if (m_role == QStringLiteral("host") && !m_applyingRemote) {
            ++m_generation;
            publishPlayback();
        }
    });
    connect(backend, &Backend::seeked, this, [this](qint64) {
        if (m_role == QStringLiteral("host") && !m_applyingRemote) {
            ++m_generation;
            publishPlayback();
        }
    });
    connect(backend, &Backend::playbackConditionChanged, this, [this] {
        if (m_role != QStringLiteral("host")) {
            correctPlayback();
            // A failed speculative source must not strand the guest on the
            // previous track.  Once Backend clears its failed prepared source,
            // retry the current successor preparation on the next condition
            // update (the authoritative transition still has a direct-load
            // fallback).
            preloadFollowingTrack();
        }
    });
}

QVariantList PartyClient::playbackQueue() const
{
    QVariantList tracks;
    tracks.reserve(m_queue.size());
    for (const auto &value : m_queue) {
        const auto wireTrack = QJsonObject::fromVariantMap(
            value.toMap().value(QStringLiteral("track")).toMap());
        tracks.append(backendTrack(wireTrack));
    }
    return tracks;
}

int PartyClient::currentQueueIndex() const
{
    const auto entryId = partyField(m_lastPlayback, QStringLiteral("entryId"),
                                    QStringLiteral("entry_id")).toString();
    for (int index = 0; index < m_queue.size(); ++index) {
        if (m_queue.at(index).toMap().value(QStringLiteral("entryId")).toString() == entryId)
            return index;
    }
    return -1;
}

void PartyClient::createParty(const QString &displayName, const QString &relayBaseUrl)
{
    if (m_active || m_creatingParty || displayName.trimmed().isEmpty()) return;
    QUrl base(relayBaseUrl.trimmed());
    if (!base.isValid() || (base.scheme() != QStringLiteral("http") && base.scheme() != QStringLiteral("https"))) {
        emit notification(QStringLiteral("Enter a valid HTTP(S) relay URL"), QStringLiteral("error"));
        return;
    }
    m_relayBaseUrl = base.toString(QUrl::RemovePath | QUrl::RemoveQuery | QUrl::RemoveFragment);
    QNetworkRequest request(QUrl(m_relayBaseUrl + QStringLiteral("/v1/party-sessions")));
    request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    auto *reply = m_network.post(request, QByteArrayLiteral("{\"ttlSeconds\":7200}"));
    m_creatingParty = true;
    QTimer::singleShot(15'000, reply, [reply] {
        if (reply->isRunning()) reply->abort();
    });
    setStatus(QStringLiteral("Creating party…"));
    connect(reply, &QNetworkReply::finished, this, [this, reply, displayName] {
        m_creatingParty = false;
        const auto body = reply->readAll();
        const auto status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const auto networkError = reply->error();
        reply->deleteLater();
        if (networkError != QNetworkReply::NoError) {
            setStatus(QStringLiteral("Could not reach the party relay"));
            emit notification(m_status, QStringLiteral("error"));
            return;
        }
        const auto document = QJsonDocument::fromJson(body);
        if (document.object().value(QStringLiteral("protocolVersion")).toInt() != PartyProtocolVersion) {
            setStatus(QStringLiteral("This relay requires a different Colorful version"));
            emit notification(m_status, QStringLiteral("error"));
            return;
        }
        const auto party = document.object().value(QStringLiteral("party")).toObject();
        if (status != 201 || party.isEmpty()) {
            setStatus(QStringLiteral("Could not allocate a party relay session"));
            emit notification(m_status, QStringLiteral("error"));
            return;
        }
        const auto session = party.value(QStringLiteral("sessionId")).toString();
        const auto hostCap = party.value(QStringLiteral("hostCapability")).toString();
        const auto guestCap = party.value(QStringLiteral("guestCapability")).toString();
        const auto expires = party.value(QStringLiteral("expiresAtMs")).toInteger();
        m_relaySessionId = session;
        m_relayHostCapability = hostCap;
        m_expiresAtMs = expires;
        const auto value = dispatchCore({
            {QStringLiteral("command"), QStringLiteral("create")},
            {QStringLiteral("display_name"), displayName.trimmed()},
            {QStringLiteral("expires_at_ms"), expires},
            {QStringLiteral("relay_session_id"), session},
            {QStringLiteral("relay_host_capability"), hostCap},
            {QStringLiteral("relay_guest_capability"), guestCap},
        });
        if (value.isEmpty()) return;
        m_inviteFragment = value.value(QStringLiteral("fragment")).toString();
        m_shareUrl = QStringLiteral("https://colorful.valerie.sh/party/%1#%2")
                         .arg(session, value.value(QStringLiteral("fragment")).toString());
        applyResult(value);
        connectRelay(m_relayBaseUrl, session, hostCap);
        m_hostClock.start();
        publishQueue();
        publishCurrentTrack();
        publishDiscordPartyState();
        refreshPublicJoinTicket();
    });
}

QString PartyClient::publicJoinTicketFromUrl(const QUrl &url)
{
    const bool custom = url.scheme() == QStringLiteral("colorful")
        && url.host() == QStringLiteral("discord") && url.path() == QStringLiteral("/join");
    const bool landing = url.scheme() == QStringLiteral("https")
        && url.host() == QStringLiteral("colorful.valerie.sh")
        && url.path() == QStringLiteral("/discord/join");
    if ((!custom && !landing) || !url.userInfo().isEmpty() || url.port() != -1
        || !url.query(QUrl::FullyEncoded).isEmpty()
        || url.fragment(QUrl::FullyEncoded).contains(QLatin1Char('%'))) return {};
    return canonicalPublicJoinTicket(url.fragment(QUrl::FullyEncoded));
}

bool PartyClient::handlePartyLink(const QString &link)
{
    const QUrl url(link);
    if (!publicJoinTicketFromUrl(url).isEmpty()) {
        emit joinLinkReceived(link);
        return true;
    }
    if ((url.scheme() == QStringLiteral("colorful") && url.host() == QStringLiteral("discord"))
        || (url.scheme() == QStringLiteral("https") && url.host() == QStringLiteral("colorful.valerie.sh")
            && url.path() == QStringLiteral("/discord/join"))) return false;
    if (partySessionFromUrl(url).isEmpty() || url.fragment(QUrl::FullyEncoded).isEmpty()) return false;
    emit joinLinkReceived(link);
    return true;
}

void PartyClient::joinPartyWithFragment(const QString &session, const QString &fragment,
                                        const QString &displayName)
{
    if (session.isEmpty() || fragment.isEmpty()) {
        emit notification(QStringLiteral("Could not open that party invite"), QStringLiteral("error"));
        return;
    }
    m_relaySessionId = session;
    const auto value = dispatchCore({
        {QStringLiteral("command"), QStringLiteral("join")},
        {QStringLiteral("display_name"), displayName.trimmed()},
        {QStringLiteral("relay_session_id"), session},
        {QStringLiteral("fragment"), fragment},
        {QStringLiteral("now_ms"), QDateTime::currentMSecsSinceEpoch()},
    });
    if (value.isEmpty()) return;
    applyResult(value);
    connectRelay(m_relayBaseUrl, session, value.value(QStringLiteral("relayCapability")).toString());
    m_clockSampler.start();
    m_driftController.start();
}

void PartyClient::joinParty(const QString &link, const QString &displayName,
                            const QString &relayBaseUrl)
{
    if (m_active || displayName.trimmed().isEmpty()) return;
    if (m_joinTicketRedemptionInFlight) {
        emit notification(QStringLiteral("A party invite is already being redeemed"), QStringLiteral("error"));
        return;
    }
    const QUrl url(link);
    const auto ticket = publicJoinTicketFromUrl(url);
    const auto session = partySessionFromUrl(url);
    if (!ticket.isEmpty()) {
        QUrl base(relayBaseUrl.trimmed());
        if (!base.isValid() || (base.scheme() != QStringLiteral("http")
                                && base.scheme() != QStringLiteral("https"))) {
            emit notification(QStringLiteral("The party link or relay URL is invalid"), QStringLiteral("error"));
            return;
        }
        m_relayBaseUrl = base.toString(QUrl::RemovePath | QUrl::RemoveQuery | QUrl::RemoveFragment);
        QNetworkRequest request(QUrl(m_relayBaseUrl + QStringLiteral("/v1/party-join-tickets/redeem")));
        request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
        auto *reply = m_network.post(request, QJsonDocument(QJsonObject{{QStringLiteral("ticketLookup"), publicJoinTicketLookup(ticket)}})
                                             .toJson(QJsonDocument::Compact));
        m_joinTicketRedemptionInFlight = true;
        const auto requestGeneration = ++m_ticketGeneration;
        QTimer::singleShot(15'000, reply, [reply] { if (reply->isRunning()) reply->abort(); });
        connect(reply, &QNetworkReply::finished, this, [this, reply, displayName, ticket, requestGeneration] {
            const auto body = reply->readAll();
            const auto status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            const auto networkError = reply->error();
            reply->deleteLater();
            if (requestGeneration != m_ticketGeneration) return;
            m_joinTicketRedemptionInFlight = false;
            if (networkError != QNetworkReply::NoError || status != 200) {
                emit notification(QStringLiteral("Could not redeem that party invite"), QStringLiteral("error"));
                return;
            }
            const auto object = QJsonDocument::fromJson(body).object();
            if (object.value(QStringLiteral("protocolVersion")).toInt() != PartyProtocolVersion) {
                emit notification(QStringLiteral("This relay requires a different Colorful version"), QStringLiteral("error"));
                return;
            }
            const auto redeemedSession = object.value(QStringLiteral("sessionId")).toString();
            const auto bootstrap = object.value(QStringLiteral("bootstrapCiphertext")).toString();
            if (redeemedSession.isEmpty() || bootstrap.isEmpty()) {
                emit notification(QStringLiteral("Could not redeem that party invite"), QStringLiteral("error"));
                return;
            }
            const auto value = dispatchCore({
                {QStringLiteral("command"), QStringLiteral("unwrap_invite_ticket")},
                {QStringLiteral("ticket"), ticket},
                {QStringLiteral("bootstrap_ciphertext"), bootstrap},
                {QStringLiteral("relay_session_id"), redeemedSession},
            }, false);
            if (value.isEmpty()) {
                emit notification(QStringLiteral("Could not open that party invite"), QStringLiteral("error"));
                return;
            }
            joinPartyWithFragment(redeemedSession, value.value(QStringLiteral("fragment")).toString(), displayName);
        });
        return;
    }
    if (session.isEmpty()) {
        emit notification(QStringLiteral("That is not a colorful party link"), QStringLiteral("error"));
        return;
    }
    const auto fragment = url.fragment(QUrl::FullyEncoded);
    QUrl base(relayBaseUrl.trimmed());
    if (fragment.isEmpty() || !base.isValid()
        || (base.scheme() != QStringLiteral("http") && base.scheme() != QStringLiteral("https"))) {
        emit notification(QStringLiteral("The party link or relay URL is invalid"), QStringLiteral("error"));
        return;
    }
    m_relayBaseUrl = base.toString(QUrl::RemovePath | QUrl::RemoveQuery | QUrl::RemoveFragment);
    const auto value = dispatchCore({
        {QStringLiteral("command"), QStringLiteral("join")},
        {QStringLiteral("display_name"), displayName.trimmed()},
        {QStringLiteral("relay_session_id"), session},
        {QStringLiteral("fragment"), fragment},
        {QStringLiteral("now_ms"), QDateTime::currentMSecsSinceEpoch()},
    });
    if (value.isEmpty()) return;
    applyResult(value);
    connectRelay(m_relayBaseUrl, session, value.value(QStringLiteral("relayCapability")).toString());
    m_clockSampler.start();
    m_driftController.start();
}

void PartyClient::connectRelay(const QString &baseUrl, const QString &sessionId,
                               const QString &capability)
{
    QUrl url(baseUrl);
    url.setScheme(url.scheme() == QStringLiteral("https") ? QStringLiteral("wss") : QStringLiteral("ws"));
    url.setPath(QStringLiteral("/v1/party-sessions/%1/relay").arg(sessionId));
    url.setQuery(QStringLiteral("protocolVersion=%1").arg(PartyProtocolVersion));
    m_socket.open(url, capability);
}

QJsonObject PartyClient::dispatchCore(const QJsonObject &command, bool reportError)
{
    QString error;
    const auto response = m_core.dispatch(command, &error);
    if (!response.value(QStringLiteral("ok")).toBool()) {
        if (!reportError) return {};
        setStatus(error.isEmpty() ? QStringLiteral("Party command failed") : error);
        emit notification(m_status, QStringLiteral("error"));
        return {};
    }
    return response.value(QStringLiteral("value")).toObject();
}

void PartyClient::dispatch(const QJsonObject &command)
{
    const auto value = dispatchCore(command);
    if (!value.isEmpty()) applyResult(value);
}

void PartyClient::applyResult(const QJsonObject &value)
{
    if (value.value(QStringLiteral("revoked")).toBool()) {
        emit notification(QStringLiteral("You were removed from the listening party"), QStringLiteral("warning"));
        leave();
        return;
    }
    const bool joinsWereEnabled = m_joinEnabled;
    if (value.contains(QStringLiteral("role"))) m_role = value.value(QStringLiteral("role")).toString();
    if (value.contains(QStringLiteral("expiresAtMs")))
        m_expiresAtMs = value.value(QStringLiteral("expiresAtMs")).toInteger();
    bool inviteRotated = false;
    if (value.contains(QStringLiteral("fragment"))) {
        const auto fragment = value.value(QStringLiteral("fragment")).toString();
        inviteRotated = !fragment.isEmpty() && fragment != m_inviteFragment;
        if (!fragment.isEmpty()) m_inviteFragment = fragment;
        if (!fragment.isEmpty() && !m_shareUrl.isEmpty()) {
            QUrl refreshed(m_shareUrl);
            refreshed.setFragment(fragment, QUrl::DecodedMode);
            m_shareUrl = refreshed.toString(QUrl::FullyEncoded);
        }
    }
    m_active = true;
    updateState(value.value(QStringLiteral("state")).toObject());
    const bool ticketBecameInvalid = m_role == QStringLiteral("host")
        && (inviteRotated || !m_joinEnabled);
    if (ticketBecameInvalid) {
        ++m_ticketGeneration;
        m_publicTicketTimer.stop();
        m_publicTicketRequestInFlight = false;
        m_publicJoinTicket.clear();
        m_publicJoinTicketLookup.clear();
        m_publicJoinTicketExpiresAtMs = 0;
    }
    publishDiscordPartyState();
    if (m_role == QStringLiteral("host")
        && (inviteRotated || (!joinsWereEnabled && m_joinEnabled)))
        refreshPublicJoinTicket();
    const auto outbound = value.value(QStringLiteral("outbound")).toArray();
    for (const auto &frame : outbound) {
        const auto bytes = QJsonDocument(frame.toObject()).toJson(QJsonDocument::Compact);
        if (m_pendingFrames.size() >= MaxPendingPartyFrames
            || m_pendingFrameBytes + bytes.size() > MaxPendingPartyBytes) {
            m_pendingFrames.clear();
            m_pendingFrameBytes = 0;
            m_needsResync = true;
            setStatus(QStringLiteral("Party connection is catching up"));
            break;
        }
        m_pendingFrameBytes += bytes.size();
        m_pendingFrames.append(bytes);
    }
    flushOutbound();
    if (value.value(QStringLiteral("event")).isObject())
        applyRemoteEvent(value.value(QStringLiteral("event")).toObject());
    emit stateChanged();
}

void PartyClient::publishDiscordPartyState()
{
    const bool partyActive = m_active && !m_relaySessionId.isEmpty();
    QString joinUrl;
    if (partyActive && m_role == QStringLiteral("host") && m_joinEnabled
        && m_backend->discordPresenceEnabled() && m_backend->discordPartyButtonEnabled()
        && m_publicJoinTicketExpiresAtMs > QDateTime::currentMSecsSinceEpoch()
        && canonicalPublicJoinTicket(m_publicJoinTicket) == m_publicJoinTicket) {
        joinUrl = QStringLiteral("https://colorful.valerie.sh/discord/join#%1")
                      .arg(m_publicJoinTicket);
    }
    m_backend->setDiscordPartyState(partyActive, m_relaySessionId,
                                    qMax(1, m_participants.size()), joinUrl);
}

void PartyClient::refreshPublicJoinTicket()
{
    const auto now = QDateTime::currentMSecsSinceEpoch();
    const bool eligible = m_active && m_role == QStringLiteral("host") && m_joinEnabled
        && m_backend->discordPresenceEnabled() && m_backend->discordPartyButtonEnabled()
        && !m_relaySessionId.isEmpty() && !m_relayHostCapability.isEmpty()
        && !m_inviteFragment.isEmpty() && isPublicPartyRelay(m_relayBaseUrl)
        && m_expiresAtMs >= now + 5'000;
    if (!eligible) {
        if (!m_publicJoinTicket.isEmpty() || m_publicTicketRequestInFlight) ++m_ticketGeneration;
        m_publicTicketTimer.stop();
        m_publicTicketRequestInFlight = false;
        m_publicJoinTicket.clear();
        m_publicJoinTicketLookup.clear();
        m_publicJoinTicketExpiresAtMs = 0;
        publishDiscordPartyState();
        return;
    }
    if (m_publicTicketRequestInFlight) return;
    if (!m_publicJoinTicket.isEmpty()
        && m_publicJoinTicketExpiresAtMs > now + PublicJoinTicketRefreshLeadMs) {
        m_publicTicketTimer.start(int(m_publicJoinTicketExpiresAtMs - now
                                      - PublicJoinTicketRefreshLeadMs));
        publishDiscordPartyState();
        return;
    }

    const auto wrapped = dispatchCore({
        {QStringLiteral("command"), QStringLiteral("wrap_invite_ticket")},
        {QStringLiteral("fragment"), m_inviteFragment},
        {QStringLiteral("relay_session_id"), m_relaySessionId},
    }, false);
    const auto ticket = wrapped.value(QStringLiteral("ticket")).toString();
    const auto ticketLookup = wrapped.value(QStringLiteral("ticketLookup")).toString();
    const auto bootstrap = wrapped.value(QStringLiteral("bootstrapCiphertext")).toString();
    if (canonicalPublicJoinTicket(ticket) != ticket
        || publicJoinTicketLookup(ticket) != ticketLookup || bootstrap.isEmpty()) {
        m_publicJoinTicket.clear();
        m_publicJoinTicketLookup.clear();
        m_publicJoinTicketExpiresAtMs = 0;
        publishDiscordPartyState();
        m_publicTicketTimer.start(PublicJoinTicketRetryMs);
        return;
    }

    const auto expiresAtMs = qMin(now + PublicJoinTicketLifetimeMs, m_expiresAtMs);
    if (expiresAtMs < now + 5'000) return;
    const auto sessionId = m_relaySessionId;
    const auto requestGeneration = ++m_ticketGeneration;
    QNetworkRequest request(QUrl(m_relayBaseUrl
                                 + QStringLiteral("/v1/party-sessions/%1/join-tickets")
                                       .arg(sessionId)));
    request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    request.setRawHeader("Authorization", QByteArrayLiteral("Bearer ")
                                           + m_relayHostCapability.toUtf8());
    const QJsonObject requestBody{
        {QStringLiteral("ticketLookup"), ticketLookup},
        {QStringLiteral("expiresAtMs"), expiresAtMs},
        {QStringLiteral("bootstrapCiphertext"), bootstrap},
    };
    auto *reply = m_network.post(request, QJsonDocument(requestBody).toJson(QJsonDocument::Compact));
    m_publicTicketRequestInFlight = true;
    QTimer::singleShot(15'000, reply, [reply] { if (reply->isRunning()) reply->abort(); });
    connect(reply, &QNetworkReply::finished, this,
            [this, reply, requestGeneration, sessionId, ticket, ticketLookup, expiresAtMs] {
        const auto body = reply->readAll();
        const auto status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const auto networkError = reply->error();
        reply->deleteLater();
        if (requestGeneration != m_ticketGeneration) return;
        m_publicTicketRequestInFlight = false;
        const auto object = QJsonDocument::fromJson(body).object();
        const bool stillEligible = m_active && m_role == QStringLiteral("host")
            && m_joinEnabled && m_relaySessionId == sessionId
            && m_backend->discordPresenceEnabled() && m_backend->discordPartyButtonEnabled();
        if (!stillEligible || networkError != QNetworkReply::NoError || status != 201
            || object.value(QStringLiteral("protocolVersion")).toInt() != PartyProtocolVersion
            || object.value(QStringLiteral("expiresAtMs")).toInteger() != expiresAtMs) {
            m_publicJoinTicket.clear();
            m_publicJoinTicketLookup.clear();
            m_publicJoinTicketExpiresAtMs = 0;
            publishDiscordPartyState();
            if (stillEligible) m_publicTicketTimer.start(PublicJoinTicketRetryMs);
            return;
        }
        m_publicJoinTicket = ticket;
        m_publicJoinTicketLookup = ticketLookup;
        m_publicJoinTicketExpiresAtMs = expiresAtMs;
        publishDiscordPartyState();
        const auto delay = qMax<qint64>(5'000, expiresAtMs
                                                  - QDateTime::currentMSecsSinceEpoch()
                                                  - PublicJoinTicketRefreshLeadMs);
        m_publicTicketTimer.start(int(delay));
    });
}

void PartyClient::flushOutbound()
{
    if (!m_socket.connected()) return;
    while (!m_pendingFrames.isEmpty()) {
        const auto frame = m_pendingFrames.takeFirst();
        m_pendingFrameBytes -= frame.size();
        m_socket.sendBinary(frame);
    }
}

void PartyClient::receiveFrame(const QByteArray &payload)
{
    QJsonParseError error;
    const auto document = QJsonDocument::fromJson(payload, &error);
    if (!document.isObject()) {
        return;
    }
    const auto value = dispatchCore({{QStringLiteral("command"), QStringLiteral("receive")},
                                     {QStringLiteral("frame"), document.object()},
                                     {QStringLiteral("received_at_ms"), clockNowMs()}},
                                    false);
    if (!value.isEmpty()) applyResult(value);
}

QJsonObject PartyClient::partyTrack(const QVariantMap &track)
{
    const auto artists = track.value(QStringLiteral("artists")).toStringList();
    auto artworkUrl = track.value(QStringLiteral("coverRemoteUrl")).toString();
    if (artworkUrl.isEmpty()) {
        const auto candidate = track.value(QStringLiteral("coverUrl")).toString();
        const QUrl candidateUrl(candidate);
        if (candidateUrl.scheme() == QStringLiteral("http")
            || candidateUrl.scheme() == QStringLiteral("https")) artworkUrl = candidate;
    }
    return {
        {QStringLiteral("mediaId"), QJsonObject{
            {QStringLiteral("provider"), track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString()},
            {QStringLiteral("providerId"), track.value(QStringLiteral("id")).toString()}}},
        {QStringLiteral("title"), track.value(QStringLiteral("title")).toString()},
        {QStringLiteral("artist"), artists.join(QStringLiteral(", "))},
        {QStringLiteral("durationMs"), track.value(QStringLiteral("durationMs")).toLongLong()},
        {QStringLiteral("artworkUrl"), artworkUrl.isEmpty()
            ? QJsonValue(QJsonValue::Null) : QJsonValue(artworkUrl)},
    };
}

QVariantMap PartyClient::backendTrack(const QJsonObject &track)
{
    const auto media = track.value(QStringLiteral("mediaId")).toObject();
    return {
        {QStringLiteral("id"), media.value(QStringLiteral("providerId")).toString()},
        {QStringLiteral("provider"), media.value(QStringLiteral("provider")).toString()},
        {QStringLiteral("title"), track.value(QStringLiteral("title")).toString()},
        {QStringLiteral("artists"), QStringList{track.value(QStringLiteral("artist")).toString()}},
        {QStringLiteral("durationMs"), track.value(QStringLiteral("durationMs")).toInteger()},
        {QStringLiteral("coverUrl"), track.value(QStringLiteral("artworkUrl")).toString()},
        {QStringLiteral("coverRemoteUrl"), track.value(QStringLiteral("artworkUrl")).toString()},
    };
}

void PartyClient::publishCurrentTrack()
{
    if (m_role != QStringLiteral("host")) return;
    const auto track = m_backend->currentTrack();
    const auto key = track.value(QStringLiteral("provider")).toString() + ':'
        + track.value(QStringLiteral("id")).toString();
    if (track.value(QStringLiteral("id")).toString().isEmpty()) return;
    publishQueue();
    const auto queueIndex = m_backend->currentQueueIndex();
    const auto partyIndex = m_partyBackendIndexes.indexOf(queueIndex);
    if (queueIndex >= 0) {
        // A queue slot with no provider id is not publishable.  Do not fall
        // back to a title/id cache here: that cache aliases duplicate queue
        // entries and can make guests jump to an older entry.
        m_currentEntryId = partyIndex >= 0 && partyIndex < m_partyEntryIds.size()
            ? m_partyEntryIds.at(partyIndex) : QString{};
    } else if (!m_entryByTrackKey.contains(key)) {
        const auto value = dispatchCore({{QStringLiteral("command"), QStringLiteral("host_track")},
                                         {QStringLiteral("track"), partyTrack(track)}});
        if (!value.isEmpty()) {
            m_entryByTrackKey.insert(key, value.value(QStringLiteral("entryId")).toString());
            applyResult(value);
        }
        m_currentEntryId = m_entryByTrackKey.value(key);
    } else {
        m_currentEntryId = m_entryByTrackKey.value(key);
    }
    m_lastTrackKey = key;
    publishPlayback();
}

void PartyClient::publishQueue()
{
    if (m_role != QStringLiteral("host")) return;
    const auto queue = m_backend->queue();
    QJsonArray tracks;
    QVector<int> backendIndexes;
    backendIndexes.reserve(queue.size());
    for (int backendIndex = 0; backendIndex < queue.size(); ++backendIndex) {
        const auto track = queue.at(backendIndex).toMap();
        if (!track.value(QStringLiteral("id")).toString().isEmpty()) {
            tracks.append(partyTrack(track));
            backendIndexes.append(backendIndex);
        }
    }

    const auto signature = QJsonDocument(tracks).toJson(QJsonDocument::Compact);
    if (signature == m_lastQueueSignature) {
        // Invalid local rows are omitted from the wire queue. They can still
        // move without changing its serialized signature, so keep the local
        // index map current even when the relay queue needs no replacement.
        m_partyBackendIndexes = backendIndexes;
        const auto partyIndex = m_partyBackendIndexes.indexOf(m_backend->currentQueueIndex());
        m_currentEntryId = partyIndex >= 0 && partyIndex < m_partyEntryIds.size()
            ? m_partyEntryIds.at(partyIndex) : QString{};
        return;
    }

    const auto result = dispatchCore({{QStringLiteral("command"), QStringLiteral("host_queue")},
                                      {QStringLiteral("tracks"), tracks}});
    if (result.isEmpty()) return;

    QStringList entryIds;
    const auto entries = result.value(QStringLiteral("entries")).toArray();
    entryIds.reserve(entries.size());
    const auto mappedEntryCount = std::min(entries.size(), backendIndexes.size());
    backendIndexes.resize(mappedEntryCount);
    for (int entryIndex = 0; entryIndex < mappedEntryCount; ++entryIndex) {
        const auto &entry = entries.at(entryIndex);
        entryIds.append(entry.toObject().value(QStringLiteral("entryId")).toString());
    }

    m_partyEntryIds = entryIds;
    m_partyBackendIndexes = backendIndexes;
    // Queue replacement invalidates any cached standalone entries.  If the
    // current track is no longer in the local queue, publishCurrentTrack will
    // mint a new authoritative entry instead of reusing a stale one.
    m_entryByTrackKey.clear();
    m_lastQueueSignature = signature;
    const auto queueIndex = m_backend->currentQueueIndex();
    const auto partyIndex = m_partyBackendIndexes.indexOf(queueIndex);
    if (partyIndex >= 0 && partyIndex < m_partyEntryIds.size())
        m_currentEntryId = m_partyEntryIds.at(partyIndex);
    else
        m_currentEntryId.clear();
    applyResult(result);
    publishPlayback();
}

void PartyClient::publishPlayback()
{
    if (m_role != QStringLiteral("host") || m_currentEntryId.isEmpty()) return;
    dispatch({
        {QStringLiteral("command"), QStringLiteral("playback")},
        {QStringLiteral("entry_id"), m_currentEntryId},
        {QStringLiteral("playing"), m_backend->playing()},
        {QStringLiteral("position_ms"), m_backend->position()},
        {QStringLiteral("host_time_ms"), clockNowMs()},
        {QStringLiteral("generation"), qint64(m_generation)},
    });
}

void PartyClient::applyRemoteEvent(const QJsonObject &event)
{
    if (m_role == QStringLiteral("host")) return;
    auto body = event.value(QStringLiteral("body")).toObject();
    auto type = body.value(QStringLiteral("type")).toString();
    if (type == QStringLiteral("clock_pong")) {
        applyClockPong(body);
        return;
    }
    if (type == QStringLiteral("track_queued") || type == QStringLiteral("queue_replaced")) {
        preloadFollowingTrack();
        return;
    }
    if (type == QStringLiteral("state_snapshot")) {
        body = body.value(QStringLiteral("playback")).toObject();
        if (body.isEmpty()) return;
        type = QStringLiteral("playback_changed");
    }
    if (type != QStringLiteral("playback_changed")) return;
    const auto generation = quint64(partyField(body, QStringLiteral("generation")).toInteger());
    // Relay order is normally enough to order events, but reconnect snapshots
    // can race with already-buffered playback events.  Never roll a guest
    // back to an older host generation.
    if (!m_lastPlayback.isEmpty() && generation < m_remoteGeneration) return;
    const bool authoritativeTransition = m_lastPlayback.isEmpty() || generation > m_remoteGeneration;
    if (authoritativeTransition) {
        m_remoteGeneration = generation;
        m_filteredDriftMs = 0.0;
        m_excessiveDriftSamples = 0;
        m_correctionRate = 1.0;
        m_backend->setPartyPlaybackRate(1.0);
    }
    m_lastPlayback = body;
    const auto entryId = partyField(body, QStringLiteral("entryId"),
                                    QStringLiteral("entry_id")).toString();
    const auto track = trackForEntry(entryId);
    if (track.isEmpty()) {
        if (!m_resyncPending) {
            emit notification(QStringLiteral("Party queue fell out of sync; requesting a fresh snapshot"),
                              QStringLiteral("warning"));
            if (m_socket.connected()) {
                m_resyncPending = true;
                dispatch({{QStringLiteral("command"), QStringLiteral("resync")} });
            }
        }
        return;
    }
    m_resyncPending = false;
    const auto local = backendTrack(track);
    const auto currentKey = m_backend->currentTrack().value(QStringLiteral("provider")).toString() + ':'
        + m_backend->currentTrack().value(QStringLiteral("id")).toString();
    const auto wantedKey = local.value(QStringLiteral("provider")).toString() + ':'
        + local.value(QStringLiteral("id")).toString();
    if (currentKey != wantedKey) {
        auto position = partyField(body, QStringLiteral("positionMs"),
                                   QStringLiteral("position_ms")).toInteger();
        if (m_clockSynchronized && partyField(body, QStringLiteral("playing")).toBool()) {
            const auto hostNow = qint64(std::llround(clockNowMs() + m_hostClockOffsetMs));
            position += qMax<qint64>(0, hostNow - partyField(body, QStringLiteral("hostTimeMs"),
                                                               QStringLiteral("host_time_ms")).toInteger());
        }
        m_applyingRemote = true;
        m_backend->loadPartyTrack(local, position,
                                  m_clockSynchronized && partyField(body, QStringLiteral("playing")).toBool());
        m_applyingRemote = false;
    }
    if (authoritativeTransition && currentKey == wantedKey && !m_backend->playbackLoading()) {
        const bool shouldPlay = partyField(body, QStringLiteral("playing")).toBool();
        auto target = partyField(body, QStringLiteral("positionMs"),
                                 QStringLiteral("position_ms")).toInteger();
        if (shouldPlay && m_clockSynchronized) {
            const auto hostNow = qint64(std::llround(clockNowMs() + m_hostClockOffsetMs));
            target += qMax<qint64>(0, hostNow - partyField(body, QStringLiteral("hostTimeMs"),
                                                             QStringLiteral("host_time_ms")).toInteger());
        }
        m_backend->setPartyPlaying(false);
        if (std::abs(target - m_backend->position()) > 35) m_backend->seekParty(target);
        m_backend->setPartyPlaying(shouldPlay);
        m_lastHardSeekMs = clockNowMs();
    }
    correctPlayback();
    preloadFollowingTrack();
}

qint64 PartyClient::clockNowMs() const
{
    return m_clockEpochMs + m_monotonicClock.elapsed();
}

void PartyClient::sendClockPing()
{
    if (m_role == QStringLiteral("host") || !m_socket.connected()) return;
    const auto nonce = ++m_clockNonce;
    const auto sent = clockNowMs();
    m_clockRequests.insert(nonce, sent);
    while (m_clockRequests.size() > 8) m_clockRequests.erase(m_clockRequests.begin());
    dispatch({{QStringLiteral("command"), QStringLiteral("clock_ping")},
              {QStringLiteral("nonce"), qint64(nonce)},
              {QStringLiteral("client_send_ms"), sent}});
}

void PartyClient::applyClockPong(const QJsonObject &body)
{
    if (body.value(QStringLiteral("participant_id")).toString() != m_participantId) return;
    const auto nonce = quint64(body.value(QStringLiteral("nonce")).toInteger());
    if (!m_clockRequests.contains(nonce)) return;
    const auto t0 = m_clockRequests.take(nonce);
    const auto t1 = body.value(QStringLiteral("host_receive_ms")).toInteger();
    const auto t2 = body.value(QStringLiteral("host_send_ms")).toInteger();
    const auto t3 = clockNowMs();
    const auto rtt = (t3 - t0) - qMax<qint64>(0, t2 - t1);
    if (rtt < 0 || rtt > 10'000) return;
    const auto sample = (double(t1 - t0) + double(t2 - t3)) / 2.0;
    if (m_bestClockRttMs < 0 || rtt < m_bestClockRttMs) m_bestClockRttMs = rtt;
    if (rtt > m_bestClockRttMs + 50) {
        if (++m_clockOutlierSamples < 5) return;
        m_bestClockRttMs = rtt;
    }
    m_clockOutlierSamples = 0;
    ++m_clockSampleCount;
    if (!m_clockSynchronized || std::abs(sample - m_hostClockOffsetMs) > 2000.0) {
        m_hostClockOffsetMs = sample;
        m_clockSynchronized = true;
    } else {
        m_hostClockOffsetMs = m_hostClockOffsetMs * 0.85 + sample * 0.15;
    }
    emit timingChanged();
    correctPlayback();
}

QJsonObject PartyClient::trackForEntry(const QString &entryId) const
{
    for (const auto &item : m_queue) {
        const auto map = item.toMap();
        if (map.value(QStringLiteral("entryId")).toString() == entryId)
            return QJsonObject::fromVariantMap(map.value(QStringLiteral("track")).toMap());
    }
    return {};
}

void PartyClient::correctPlayback()
{
    if (m_role == QStringLiteral("host") || !m_clockSynchronized || m_lastPlayback.isEmpty()) return;
    const auto track = trackForEntry(partyField(m_lastPlayback, QStringLiteral("entryId"),
                                                QStringLiteral("entry_id")).toString());
    if (track.isEmpty() || m_backend->playbackLoading()) return;
    const auto local = backendTrack(track);
    const auto wantedKey = local.value(QStringLiteral("provider")).toString() + ':'
        + local.value(QStringLiteral("id")).toString();
    const auto currentKey = m_backend->currentTrack().value(QStringLiteral("provider")).toString() + ':'
        + m_backend->currentTrack().value(QStringLiteral("id")).toString();
    if (wantedKey != currentKey) return;

    const bool shouldPlay = partyField(m_lastPlayback, QStringLiteral("playing")).toBool();
    auto target = partyField(m_lastPlayback, QStringLiteral("positionMs"),
                             QStringLiteral("position_ms")).toInteger();
    if (shouldPlay) {
        const auto hostNow = qint64(std::llround(clockNowMs() + m_hostClockOffsetMs));
        target += qMax<qint64>(0, hostNow - partyField(m_lastPlayback, QStringLiteral("hostTimeMs"),
                                                        QStringLiteral("host_time_ms")).toInteger());
    }
    const auto rawDrift = target - m_backend->position();
    m_filteredDriftMs = m_filteredDriftMs == 0.0
        ? double(rawDrift)
        : m_filteredDriftMs * 0.8 + double(rawDrift) * 0.2;
    const auto drift = qint64(std::llround(m_filteredDriftMs));
    if (std::abs(drift - m_lastDriftMs) >= 5) {
        m_lastDriftMs = drift;
        emit timingChanged();
    }
    const auto magnitude = std::abs(drift);
    m_excessiveDriftSamples = magnitude > 90 ? m_excessiveDriftSamples + 1 : 0;

    // Decoder position reports are quantized and naturally wobble by a few
    // dozen milliseconds. Do not touch mpv's speed unless the filtered error
    // remains audible for at least 1.5 seconds. Once correcting, hysteresis
    // keeps the rate stable until the error is genuinely gone.
    if (magnitude > 500 && m_excessiveDriftSamples >= 3
        && clockNowMs() - m_lastHardSeekMs > 3000) {
        m_lastHardSeekMs = clockNowMs();
        ++m_hardResyncCount;
        m_excessiveDriftSamples = 0;
        m_filteredDriftMs = 0.0;
        if (m_correctionRate != 1.0) {
            m_correctionRate = 1.0;
            m_backend->setPartyPlaybackRate(1.0);
        }
        m_backend->seekParty(target);
    } else if (shouldPlay && m_correctionRate == 1.0
               && m_excessiveDriftSamples >= 6
               && clockNowMs() - m_lastRateChangeMs > 2000) {
        m_correctionRate = drift > 0 ? 1.005 : 0.995;
        m_lastRateChangeMs = clockNowMs();
        m_backend->setPartyPlaybackRate(m_correctionRate);
        emit timingChanged();
    } else if (m_correctionRate != 1.0 && magnitude < 35
               && clockNowMs() - m_lastRateChangeMs > 2000) {
        m_correctionRate = 1.0;
        m_lastRateChangeMs = clockNowMs();
        m_backend->setPartyPlaybackRate(1.0);
        emit timingChanged();
    }
    if (m_backend->playing() != shouldPlay) m_backend->setPartyPlaying(shouldPlay);
}

void PartyClient::preloadFollowingTrack()
{
    if (m_role == QStringLiteral("host") || m_lastPlayback.isEmpty()) return;
    const auto current = partyField(m_lastPlayback, QStringLiteral("entryId"),
                                    QStringLiteral("entry_id")).toString();
    for (int index = 0; index + 1 < m_queue.size(); ++index) {
        if (m_queue.at(index).toMap().value(QStringLiteral("entryId")).toString() != current) continue;
        const auto next = QJsonObject::fromVariantMap(
            m_queue.at(index + 1).toMap().value(QStringLiteral("track")).toMap());
        if (!next.isEmpty()) m_backend->preparePartyTrack(backendTrack(next));
        return;
    }
}

void PartyClient::updateState(const QJsonObject &state)
{
    if (state.isEmpty()) return;
    if (state.contains(QStringLiteral("role"))) m_role = state.value(QStringLiteral("role")).toString();
    if (state.contains(QStringLiteral("participantId")))
        m_participantId = state.value(QStringLiteral("participantId")).toString();
    if (state.contains(QStringLiteral("joinEnabled")))
        m_joinEnabled = state.value(QStringLiteral("joinEnabled")).toBool();
    m_participants = state.value(QStringLiteral("participants")).toArray().toVariantList();
    m_queue = state.value(QStringLiteral("queue")).toArray().toVariantList();
}

void PartyClient::suggestTrack(const QVariantMap &track)
{
    if (m_role == QStringLiteral("guest") && m_socket.connected())
        dispatch({{QStringLiteral("command"), QStringLiteral("suggest")},
                  {QStringLiteral("track"), partyTrack(track)}});
}

void PartyClient::enqueueTrack(const QVariantMap &track)
{
    if (m_role == QStringLiteral("co_host") && m_socket.connected())
        dispatch({{QStringLiteral("command"), QStringLiteral("enqueue")},
                  {QStringLiteral("track"), partyTrack(track)}});
}

void PartyClient::setJoinEnabled(bool enabled)
{
    if (m_role == QStringLiteral("host"))
        dispatch({{QStringLiteral("command"), QStringLiteral("set_join_enabled")},
                  {QStringLiteral("enabled"), enabled}});
}

void PartyClient::setCoHost(const QString &participantId, bool enabled)
{
    if (m_role == QStringLiteral("host"))
        dispatch({{QStringLiteral("command"), QStringLiteral("set_role")},
                  {QStringLiteral("participant_id"), participantId},
                  {QStringLiteral("role"), enabled ? QStringLiteral("co_host") : QStringLiteral("guest")}});
}

void PartyClient::kick(const QString &participantId)
{
    if (m_role == QStringLiteral("host"))
        dispatch({{QStringLiteral("command"), QStringLiteral("kick")},
                  {QStringLiteral("participant_id"), participantId}});
}

void PartyClient::leave()
{
    ++m_ticketGeneration;
    m_publicTicketTimer.stop();
    m_publicJoinTicket.clear();
    m_publicJoinTicketLookup.clear();
    m_publicJoinTicketExpiresAtMs = 0;
    m_relaySessionId.clear();
    m_relayHostCapability.clear();
    m_inviteFragment.clear();
    m_publicTicketRequestInFlight = false;
    m_joinTicketRedemptionInFlight = false;
    m_backend->setDiscordPartyState(false, {}, 0, {});
    if (m_active && m_role != QStringLiteral("host") && m_socket.connected()) {
        const auto value = dispatchCore({{QStringLiteral("command"), QStringLiteral("leave")}}, false);
        for (const auto &frame : value.value(QStringLiteral("outbound")).toArray())
            m_socket.sendBinary(QJsonDocument(frame.toObject()).toJson(QJsonDocument::Compact));
        m_socket.closeGracefully();
    } else {
        m_socket.close();
    }
    m_hostClock.stop();
    m_clockSampler.stop();
    m_driftController.stop();
    m_pendingFrames.clear();
    m_pendingFrameBytes = 0;
    m_active = false;
    m_everConnected = false;
    m_role.clear();
    m_shareUrl.clear();
    m_expiresAtMs = 0;
    m_joinEnabled = true;
    m_participants.clear();
    m_queue.clear();
    m_currentEntryId.clear();
    m_lastTrackKey.clear();
    m_entryByTrackKey.clear();
    m_partyEntryIds.clear();
    m_partyBackendIndexes.clear();
    m_lastQueueSignature.clear();
    m_clockRequests.clear();
    m_lastPlayback = {};
    m_clockSynchronized = false;
    m_bestClockRttMs = -1;
    m_clockOutlierSamples = 0;
    m_hostClockOffsetMs = 0.0;
    m_lastDriftMs = 0;
    m_filteredDriftMs = 0.0;
    m_excessiveDriftSamples = 0;
    m_correctionRate = 1.0;
    m_remoteGeneration = 0;
    m_clockSampleCount = 0;
    m_hardResyncCount = 0;
    m_needsResync = false;
    m_resyncPending = false;
    emit timingChanged();
    m_backend->leavePartyPlayback();
    QString resetError;
    if (!m_core.reset(&resetError))
        emit notification(resetError, QStringLiteral("error"));
    setStatus(QStringLiteral("No active party"));
    emit stateChanged();
}

void PartyClient::setStatus(const QString &status)
{
    if (m_status == status) return;
    m_status = status;
    emit stateChanged();
}
