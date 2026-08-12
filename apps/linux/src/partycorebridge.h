#pragma once

#include <QJsonObject>
#include <QString>
#include <cstdint>

class PartyCoreBridge final
{
public:
    PartyCoreBridge();
    ~PartyCoreBridge();
    PartyCoreBridge(const PartyCoreBridge &) = delete;
    PartyCoreBridge &operator=(const PartyCoreBridge &) = delete;

    QJsonObject dispatch(const QJsonObject &command, QString *error = nullptr) const;
    bool reset(QString *error = nullptr);
    bool isOpen() const { return m_handle != 0; }

private:
    static QJsonObject takeResponse(char *value, QString *error);
    std::uint64_t m_handle = 0;
};
