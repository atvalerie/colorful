#include "partycorebridge.h"

#include "colorful_core.h"
#include <QJsonDocument>

PartyCoreBridge::PartyCoreBridge()
{
    reset();
}

PartyCoreBridge::~PartyCoreBridge()
{
    if (m_handle != 0) colorful_party_close(m_handle);
}

bool PartyCoreBridge::reset(QString *error)
{
    if (m_handle != 0) colorful_party_close(m_handle);
    m_handle = 0;
    const auto response = takeResponse(colorful_party_open(), error);
    m_handle = response.value(QStringLiteral("value")).toObject()
                   .value(QStringLiteral("handle")).toInteger();
    return m_handle != 0;
}

QJsonObject PartyCoreBridge::dispatch(const QJsonObject &command, QString *error) const
{
    if (m_handle == 0) {
        if (error) *error = QStringLiteral("party core is unavailable");
        return {};
    }
    const auto bytes = QJsonDocument(command).toJson(QJsonDocument::Compact);
    return takeResponse(colorful_party_dispatch(m_handle, bytes.constData()), error);
}

QJsonObject PartyCoreBridge::takeResponse(char *value, QString *error)
{
    if (!value) {
        if (error) *error = QStringLiteral("party core returned no response");
        return {};
    }
    const QByteArray bytes(value);
    colorful_string_free(value);
    QJsonParseError parseError;
    const auto document = QJsonDocument::fromJson(bytes, &parseError);
    if (!document.isObject()) {
        if (error) *error = QStringLiteral("party core returned malformed JSON: %1")
                                .arg(parseError.errorString());
        return {};
    }
    const auto response = document.object();
    if (!response.value(QStringLiteral("ok")).toBool() && error)
        *error = response.value(QStringLiteral("error")).toString();
    return response;
}
