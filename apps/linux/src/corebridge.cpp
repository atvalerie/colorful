#include "corebridge.h"

#include "colorful_core.h"

#include <QJsonDocument>

void CoreBridge::HandleDeleter::operator()(std::uint64_t *handle) const noexcept
{
    if (!handle) return;
    colorful_engine_close(*handle);
    delete handle;
}

bool CoreBridge::open(const QString &databasePath, QString *error)
{
    if (m_handle != nullptr) return true;
    const auto path = databasePath.toUtf8();
    const auto response = takeResponse(colorful_engine_open(path.constData()), error);
    if (!response.value(QStringLiteral("ok")).toBool()) return false;
    const auto handle = static_cast<std::uint64_t>(
        response.value(QStringLiteral("value")).toObject().value(QStringLiteral("handle"))
            .toInteger());
    if (handle == 0) {
        if (error) *error = QStringLiteral("colorful core returned an invalid engine handle");
        return false;
    }
    try {
        m_handle.reset(new std::uint64_t(handle));
    } catch (...) {
        colorful_engine_close(handle);
        if (error) *error = QStringLiteral("could not allocate a colorful core handle");
        return false;
    }
    return true;
}

QJsonObject CoreBridge::dispatch(const QJsonObject &command, QString *error) const
{
    if (m_handle == nullptr) {
        if (error) *error = QStringLiteral("colorful core is not open");
        return {};
    }
    const auto json = QJsonDocument(command).toJson(QJsonDocument::Compact);
    return takeResponse(colorful_engine_dispatch(*m_handle, json.constData()), error);
}

QJsonObject CoreBridge::snapshot(QString *error) const
{
    if (m_handle == nullptr) {
        if (error) *error = QStringLiteral("colorful core is not open");
        return {};
    }
    return takeResponse(colorful_engine_snapshot(*m_handle), error);
}

QJsonObject CoreBridge::exportTravelSnapshot(QString *error) const
{
    if (m_handle == nullptr) {
        if (error) *error = QStringLiteral("colorful core is not open");
        return {};
    }
    return takeResponse(colorful_engine_export_travel_snapshot(*m_handle), error);
}

QJsonObject CoreBridge::importTravelSnapshot(const QByteArray &snapshotJson, QString *error) const
{
    if (m_handle == nullptr) {
        if (error) *error = QStringLiteral("colorful core is not open");
        return {};
    }
    return takeResponse(
        colorful_engine_import_travel_snapshot(*m_handle, snapshotJson.constData()), error);
}

QJsonValue CoreBridge::setting(const QString &key, QString *error) const
{
    if (m_handle == nullptr) {
        if (error) *error = QStringLiteral("colorful core is not open");
        return {};
    }
    const auto bytes = key.toUtf8();
    return takeResponse(colorful_engine_setting(*m_handle, bytes.constData()), error)
        .value(QStringLiteral("value"));
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
