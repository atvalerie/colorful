#define DISCORDPP_IMPLEMENTATION
#include <discordpp.h>

#include "discordsocial.h"

#include "credentialstore.h"
#include "debuglog.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QHash>
#include <QRegularExpression>
#include <QTimer>
#include <QUrl>

#include <algorithm>
#include <limits>

namespace {
constexpr uint64_t applicationId = 1528095256820842606ULL;
constexpr auto refreshCredentialName = "discord/social-sdk-refresh-token";

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
    return ticketPattern.match(url.fragment(QUrl::FullyEncoded)).hasMatch()
        ? url.toString(QUrl::FullyEncoded) : QString{};
}

QString validJoinSecret(const QString &value)
{
    static const QRegularExpression ticketPattern(
        QStringLiteral("^v1\\.[A-Za-z0-9_-]{43}\\.[A-Za-z0-9_-]{43}$"));
    const auto candidate = value.trimmed();
    return ticketPattern.match(candidate).hasMatch() ? candidate : QString{};
}

QString validDiscordUserId(const QString &value)
{
    static const QRegularExpression snowflake(QStringLiteral("^[0-9]{8,20}$"));
    return snowflake.match(value.trimmed()).hasMatch() ? value.trimmed() : QString{};
}

std::string utf8(const QString &value)
{
    return value.toUtf8().toStdString();
}

QString fromUtf8(const std::string &value)
{
    return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
}

void logSdkResult(const QString &operation, const discordpp::ClientResult &result)
{
    if (result.Successful()) return;
    DebugLog::write(u"discord", QStringLiteral("Social SDK %1 failed: %2")
                                   .arg(operation, fromUtf8(result.ToString()).left(300)));
}
}

struct DiscordSocial::Private {
    std::unique_ptr<discordpp::Client> client;
    QTimer callbacks;
    QHash<QString, discordpp::ActivityInvite> pendingRequests;
    QString authorizationVerifier;
    bool authorizing = false;
    bool connected = false;
    qint64 lastPresenceUpdateMs = 0;
};

DiscordSocial::DiscordSocial(QObject *parent)
    : QObject(parent), m_private(std::make_unique<Private>())
{
    m_enabled = !qEnvironmentVariableIsSet("COLORFUL_DISABLE_DISCORD_SOCIAL");
    m_private->client = std::make_unique<discordpp::Client>();
    m_private->client->SetApplicationId(applicationId);
    // Registering the installed executable lets Discord start Colorful when an
    // invite is accepted while it is not already open. The running-client
    // callback still handles the join secret without exposing it in argv.
    if (!m_private->client->RegisterLaunchCommand(applicationId,
                                                   utf8(QCoreApplication::applicationFilePath()))) {
        DebugLog::write(u"discord", QStringLiteral("Social SDK could not register its launch command"));
    }
    m_private->client->AddLogCallback([](std::string message, discordpp::LoggingSeverity) {
        const auto text = fromUtf8(message).trimmed();
        if (!text.isEmpty()) DebugLog::write(u"discord", QStringLiteral("Social SDK: %1").arg(text.left(300)));
    }, discordpp::LoggingSeverity::Warning);
    m_private->client->SetStatusChangedCallback([this](discordpp::Client::Status status,
                                                        discordpp::Client::Error error,
                                                        int32_t detail) {
        const bool ready = status == discordpp::Client::Status::Ready;
        setReady(ready);
        if (error != discordpp::Client::Error::None) {
            DebugLog::write(u"discord", QStringLiteral("Social SDK connection status=%1 error=%2 detail=%3")
                                           .arg(static_cast<int>(status)).arg(static_cast<int>(error)).arg(detail));
        }
        if (ready) publish();
    });
    m_private->client->SetActivityJoinCallback([this](std::string secret) {
        const auto ticket = validJoinSecret(fromUtf8(secret));
        if (ticket.isEmpty()) {
            DebugLog::write(u"discord", QStringLiteral("Social SDK received an invalid activity join secret"));
            return;
        }
        DebugLog::write(u"discord", QStringLiteral("Social SDK received an activity join request"));
        emit activityJoin(ticket);
    });
    m_private->client->SetActivityInviteCreatedCallback([this](discordpp::ActivityInvite invite) {
        if (invite.Type() != discordpp::ActivityActionTypes::JoinRequest) return;
        const auto id = QString::number(invite.SenderId());
        if (validDiscordUserId(id).isEmpty() || m_private->pendingRequests.contains(id)) return;
        m_private->pendingRequests.insert(id, std::move(invite));
        QVariantMap user{{QStringLiteral("id"), id}};
        if (const auto handle = m_private->client->GetUser(m_private->pendingRequests.value(id).SenderId())) {
            const auto displayName = fromUtf8(handle->DisplayName()).left(64);
            if (!displayName.isEmpty()) user.insert(QStringLiteral("globalName"), displayName);
        }
        emit activityJoinRequested(user);
    });
    m_private->callbacks.setInterval(16);
    connect(&m_private->callbacks, &QTimer::timeout, this, [] { discordpp::RunCallbacks(); });
    if (m_enabled) m_private->callbacks.start();
}

DiscordSocial::~DiscordSocial()
{
    shutdown();
}

void DiscordSocial::shutdown()
{
    if (!m_private) return;
    m_private->callbacks.stop();
    if (m_private->client) {
        m_private->client->ClearRichPresence();
        m_private->client->Disconnect();
    }
    setReady(false);
}

void DiscordSocial::setEnabled(bool enabled)
{
    const bool effective = enabled && !qEnvironmentVariableIsSet("COLORFUL_DISABLE_DISCORD_SOCIAL");
    if (m_enabled == effective) return;
    m_enabled = effective;
    if (!m_enabled) {
        clear();
        m_private->callbacks.stop();
        m_private->client->Disconnect();
        setReady(false);
        return;
    }
    m_private->callbacks.start();
    if (m_askToJoinEnabled) ensureAuthenticated();
    // A party activity needs an authenticated Social SDK connection. Keep the
    // desired state locally until that connection reaches Ready; publishing
    // before then causes Discord clients to briefly cache a partial activity.
    if (m_ready) publish();
}

void DiscordSocial::setTrackButtonEnabled(bool enabled)
{
    if (m_trackButtonEnabled == enabled) return;
    m_trackButtonEnabled = enabled;
    if (m_ready) publish();
}

void DiscordSocial::setAskToJoinEnabled(bool enabled)
{
    if (m_askToJoinEnabled == enabled) return;
    m_askToJoinEnabled = enabled;
    if (enabled) ensureAuthenticated();
    publish();
}

void DiscordSocial::respondToJoinRequest(const QString &userId, bool approved)
{
    const auto id = validDiscordUserId(userId);
    if (id.isEmpty() || !m_ready || !m_private->pendingRequests.contains(id)) return;
    const auto invite = m_private->pendingRequests.take(id);
    if (!approved) return;
    m_private->client->SendActivityJoinRequestReply(invite, [](discordpp::ClientResult result) {
        logSdkResult(QStringLiteral("join-request reply"), result);
    });
}

void DiscordSocial::update(const QString &title, const QString &artist, const QString &album,
                           const QString &artworkUrl, qint64 positionMs, qint64 durationMs,
                           bool playing, const QString &trackUrl, const QString &partyId,
                           int partySize, const QString &joinPartyUrl, const QString &joinSecret)
{
    if (!m_enabled || title.trimmed().isEmpty()) {
        clear();
        return;
    }
    m_title = title.left(128);
    m_artist = artist.left(128);
    m_album = album.left(128);
    m_artworkUrl = validHttpUrl(artworkUrl);
    m_positionMs = std::max<qint64>(0, positionMs);
    m_durationMs = std::max<qint64>(0, durationMs);
    m_playing = playing;
    m_trackUrl = validHttpUrl(trackUrl);
    m_partyId = partyId.trimmed().left(128);
    m_partySize = std::clamp(partySize, 0, 64);
    m_joinPartyUrl = validJoinPartyUrl(joinPartyUrl);
    m_joinSecret = validJoinSecret(joinSecret);
    m_hasActivity = true;
    if (m_askToJoinEnabled) ensureAuthenticated();
    if (m_ready) publish();
}

void DiscordSocial::clear()
{
    if (!m_hasActivity) return;
    m_hasActivity = false;
    m_private->pendingRequests.clear();
    if (m_private->client) m_private->client->ClearRichPresence();
}

void DiscordSocial::ensureAuthenticated()
{
    if (!m_enabled || !m_askToJoinEnabled || m_private->authorizing || m_ready) return;
    m_private->authorizing = true;
    const auto refreshToken = loadCredential(QString::fromLatin1(refreshCredentialName));
    const auto useToken = [this](discordpp::ClientResult result, std::string accessToken,
                                 std::string refreshTokenValue, discordpp::AuthorizationTokenType tokenType,
                                 int32_t, std::string) {
        if (!result.Successful() || accessToken.empty()) {
            logSdkResult(QStringLiteral("token exchange"), result);
            m_private->authorizing = false;
            return;
        }
        if (!refreshTokenValue.empty()) saveCredential(QString::fromLatin1(refreshCredentialName), QByteArray::fromStdString(refreshTokenValue));
        m_private->client->UpdateToken(tokenType, std::move(accessToken), [this](discordpp::ClientResult updateResult) {
            m_private->authorizing = false;
            logSdkResult(QStringLiteral("token update"), updateResult);
            if (updateResult.Successful()) m_private->client->Connect();
        });
    };
    if (!refreshToken.isEmpty()) {
        m_private->client->RefreshToken(applicationId, refreshToken.toStdString(), useToken);
        return;
    }
    const auto verifier = m_private->client->CreateAuthorizationCodeVerifier();
    m_private->authorizationVerifier = fromUtf8(verifier.Verifier());
    discordpp::AuthorizationArgs arguments;
    arguments.SetClientId(applicationId);
    arguments.SetScopes(discordpp::Client::GetDefaultPresenceScopes());
    arguments.SetCodeChallenge(verifier.Challenge());
    m_private->client->Authorize(std::move(arguments), [this, useToken](discordpp::ClientResult result,
                                                                         std::string code,
                                                                         std::string redirectUri) {
        if (!result.Successful() || code.empty() || redirectUri.empty()) {
            logSdkResult(QStringLiteral("authorization"), result);
            m_private->authorizing = false;
            return;
        }
        m_private->client->GetToken(applicationId, code, utf8(m_private->authorizationVerifier), redirectUri, useToken);
    });
}

void DiscordSocial::publish()
{
    if (!m_enabled || !m_ready || !m_hasActivity || !m_private->client) return;
    const auto now = QDateTime::currentMSecsSinceEpoch();
    // UpdateRichPresence goes through the Social API, which has a much tighter
    // rate limit than the desktop RPC. Coalesce duplicate state refreshes that
    // often arrive together while playback and party state are settling.
    if (now - m_private->lastPresenceUpdateMs < 2'000) return;
    m_private->lastPresenceUpdateMs = now;
    discordpp::Activity activity;
    // Social SDK documents Playing as the interoperable type for party
    // activities. The detail keeps the music-focused presentation clear.
    activity.SetType(discordpp::ActivityTypes::Playing);
    activity.SetDetails(utf8(m_title));
    const auto state = m_playing ? m_artist : (m_artist.isEmpty() ? QStringLiteral("Paused")
                                                                   : m_artist + QStringLiteral(" · Paused"));
    if (!state.isEmpty()) activity.SetState(utf8(state.left(128)));
    if (m_playing) {
        discordpp::ActivityTimestamps timestamps;
        const auto start = static_cast<uint64_t>(std::max<qint64>(0, now - m_positionMs));
        timestamps.SetStart(start);
        if (m_durationMs > 0) timestamps.SetEnd(start + static_cast<uint64_t>(m_durationMs));
        activity.SetTimestamps(std::move(timestamps));
    }
    // Social SDK resolves external artwork server-side. Provider CDN URLs can
    // reject that fetch, and Discord rejects the entire activity when they do.
    // Keep party presence functional first; a portal-hosted Colorful asset can
    // be added here later without making joinability depend on cover art.
    if (m_trackButtonEnabled && !m_trackUrl.isEmpty()) {
        discordpp::ActivityButton button;
        button.SetLabel("View Track");
        button.SetUrl(utf8(m_trackUrl));
        activity.AddButton(std::move(button));
    }
    if (!m_partyId.isEmpty() && !m_joinPartyUrl.isEmpty()) {
        discordpp::ActivityButton button;
        button.SetLabel("Join Party");
        button.SetUrl(utf8(m_joinPartyUrl));
        activity.AddButton(std::move(button));
    }
    if (!m_partyId.isEmpty()) {
        discordpp::ActivityParty party;
        party.SetId(utf8(m_partyId));
        party.SetCurrentSize(std::max(1, m_partySize));
        party.SetMaxSize(64);
        // Private makes Discord expose the approval-based Ask to Join action.
        party.SetPrivacy(discordpp::ActivityPartyPrivacy::Private);
        activity.SetParty(std::move(party));
        if (m_ready && m_askToJoinEnabled && !m_joinSecret.isEmpty()) {
            discordpp::ActivitySecrets secrets;
            secrets.SetJoin(utf8(m_joinSecret));
            activity.SetSecrets(std::move(secrets));
            activity.SetSupportedPlatforms(discordpp::ActivityGamePlatforms::Desktop);
        }
    }
    m_private->client->UpdateRichPresence(std::move(activity), [](discordpp::ClientResult result) {
        logSdkResult(QStringLiteral("rich presence update"), result);
    });
}

void DiscordSocial::setReady(bool ready)
{
    if (m_ready == ready) return;
    m_ready = ready;
    emit readyChanged(ready);
}
