#pragma once

#include <QObject>

#include <memory>

class DiscordSocial final : public QObject
{
    Q_OBJECT

public:
    explicit DiscordSocial(QObject *parent = nullptr);
    ~DiscordSocial() override;

    void shutdown();
    void setEnabled(bool enabled);
    void setTrackButtonEnabled(bool enabled);
    void setAskToJoinEnabled(bool enabled);
    void respondToJoinRequest(const QString &userId, bool approved);
    void update(const QString &title,
                const QString &artist,
                const QString &album,
                const QString &artworkUrl,
                qint64 positionMs,
                qint64 durationMs,
                bool playing,
                const QString &trackUrl = {},
                const QString &partyId = {},
                int partySize = 0,
                const QString &joinPartyUrl = {},
                const QString &joinSecret = {});
    void clear();

signals:
    void readyChanged(bool ready);
    void activityJoinRequested(const QVariantMap &user);
    void activityJoin(const QString &joinSecret);

private:
    struct Private;

    void ensureAuthenticated();
    void publish();
    void setReady(bool ready);

    std::unique_ptr<Private> m_private;
    bool m_enabled = true;
    bool m_trackButtonEnabled = true;
    bool m_askToJoinEnabled = false;
    bool m_ready = false;
    bool m_hasActivity = false;
    QString m_title;
    QString m_artist;
    QString m_album;
    QString m_artworkUrl;
    qint64 m_positionMs = 0;
    qint64 m_durationMs = 0;
    bool m_playing = false;
    QString m_trackUrl;
    QString m_partyId;
    int m_partySize = 0;
    QString m_joinPartyUrl;
    QString m_joinSecret;
};
