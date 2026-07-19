#pragma once

#include <QByteArray>
#include <QNetworkAccessManager>
#include <QObject>
#include <QTimer>
#include <QVariantMap>

class DiscordWidgetExporter final : public QObject
{
    Q_OBJECT

public:
    explicit DiscordWidgetExporter(QObject *parent = nullptr);

    bool enabled() const { return m_enabled; }
    bool configured() const { return !m_token.isEmpty(); }
    bool busy() const { return m_busy; }
    QString status() const { return m_status; }
    QString applicationId() const { return m_applicationId; }
    QString redirectUri() const { return m_redirectUri; }
    QString userId() const { return m_userId; }
    bool userIdAutomatic() const { return m_userIdOverride.isEmpty(); }

    void setStats(const QVariantMap &stats);
    void setEnabled(bool enabled);
    void setApplicationId(const QString &applicationId);
    void setRedirectUri(const QString &redirectUri);
    void setUserId(const QString &userId);
    void setUserIdOverride(const QString &userId);
    void authorize();
    void storeToken(const QString &token);
    void forgetToken();
    void publishNow();

signals:
    void stateChanged();

private:
    void loadToken();
    void schedulePublish(bool manual = false);
    void publish(bool manual);
    void setBusy(bool busy);
    void setStatus(const QString &status);
    QByteArray payload() const;

    QNetworkAccessManager m_network;
    QTimer m_publishTimer;
    QVariantMap m_stats;
    QByteArray m_token;
    QByteArray m_pendingPayload;
    bool m_enabled = false;
    bool m_busy = false;
    bool m_manualPublish = false;
    QString m_status = QStringLiteral("Discord widget is not configured");
    QString m_userId;
    QString m_detectedUserId;
    QString m_userIdOverride;
    QString m_applicationId;
    QString m_redirectUri;
};
