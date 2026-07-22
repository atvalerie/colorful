#pragma once

#include <QByteArray>
#include <QString>

QByteArray loadCredential(const QString &name, QString *error = nullptr);
bool saveCredential(const QString &name, const QByteArray &value, QString *error = nullptr);
bool deleteCredential(const QString &name, QString *error = nullptr);
