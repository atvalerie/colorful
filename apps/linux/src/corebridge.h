#pragma once

#include <QJsonObject>
#include <QString>
#include <cstdint>

class CoreBridge final
{
public:
    CoreBridge() = default;
    ~CoreBridge();

    CoreBridge(const CoreBridge &) = delete;
    CoreBridge &operator=(const CoreBridge &) = delete;

    bool open(const QString &databasePath, QString *error = nullptr);
    QJsonObject dispatch(const QJsonObject &command, QString *error = nullptr) const;
    QJsonObject snapshot(QString *error = nullptr) const;
    bool isOpen() const { return m_handle != 0; }

private:
    static QJsonObject takeResponse(char *value, QString *error);
    std::uint64_t m_handle = 0;
};
