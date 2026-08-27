#pragma once

#include <QByteArray>
#include <QJsonObject>
#include <QString>
#include <cstdint>
#include <memory>

class CoreBridge final
{
public:
    CoreBridge() = default;

    CoreBridge(const CoreBridge &) = delete;
    CoreBridge &operator=(const CoreBridge &) = delete;

    bool open(const QString &databasePath, QString *error = nullptr);
    QJsonObject dispatch(const QJsonObject &command, QString *error = nullptr) const;
    QJsonObject snapshot(QString *error = nullptr) const;
    QJsonObject exportTravelSnapshot(QString *error = nullptr) const;
    QJsonObject importTravelSnapshot(const QByteArray &snapshotJson,
                                     QString *error = nullptr) const;
    QJsonValue setting(const QString &key, QString *error = nullptr) const;
    bool isOpen() const { return m_handle != nullptr; }

private:
    struct HandleDeleter {
        void operator()(std::uint64_t *handle) const noexcept;
    };
    using Handle = std::unique_ptr<std::uint64_t, HandleDeleter>;

    static QJsonObject takeResponse(char *value, QString *error);
    Handle m_handle;
};
