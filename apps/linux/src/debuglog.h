#pragma once

#include <QString>
#include <QStringView>

namespace DebugLog {
QString filePath();
void write(QStringView component, QStringView message);
}
