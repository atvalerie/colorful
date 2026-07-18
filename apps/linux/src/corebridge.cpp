#include "corebridge.h"

#include "colorful_core.h"

#include <QJsonDocument>

CoreBridge::~CoreBridge()
{
    if (m_handle != 0) colorful_engine_close(m_handle);
}

bool CoreBridge::open(const QString &databasePath, QString *error)
{
    if (m_handle != 0) return true;
    const auto path = databasePath.toUtf8();
    const auto response = takeResponse(colorful_engine_open(path.constData()), error);
    if (!response.value(QStringLiteral("ok")).toBool()) return false;
    m_handle = response.value(QStringLiteral("value")).toObject().value(QStringLiteral("handle")).toInteger();
    if (m_handle == 0 && error) *error = QStringLiteral("colorful core returned an invalid engine handle");
    return m_handle != 0;
}

QJsonObject CoreBridge::dispatch(const QJsonObject &command, QString *error) const
{
    if (m_handle == 0) {
        if (error) *error = QStringLiteral("colorful core is not open");
        return {};
    }
    const auto json = QJsonDocument(command).toJson(QJsonDocument::Compact);
    return takeResponse(colorful_engine_dispatch(m_handle, json.constData()), error);
}

QJsonObject CoreBridge::snapshot(QString *error) const
{
    if (m_handle == 0) {
        if (error) *error = QStringLiteral("colorful core is not open");
        return {};
    }
    return takeResponse(colorful_engine_snapshot(m_handle), error);
}

QJsonObject CoreBridge::takeResponse(char *value, QString *error)
{
    if (!value) {
        if (error) *error = QStringLiteral("colorful core returned no response");
        return {};
    }
    const auto bytes = QByteArray(value);
    colorful_string_free(value);
    QJsonParseError parseError;
    const auto document = QJsonDocument::fromJson(bytes, &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        if (error) *error = QStringLiteral("colorful core returned malformed JSON: %1").arg(parseError.errorString());
        return {};
    }
    const auto response = document.object();
    if (!response.value(QStringLiteral("ok")).toBool() && error) {
        *error = response.value(QStringLiteral("error")).toString(QStringLiteral("colorful core command failed"));
    }
    return response;
}
