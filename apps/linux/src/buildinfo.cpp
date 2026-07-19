#include "buildinfo.h"
#include "buildinfo_generated.h"

#include <QSysInfo>
#include <QtGlobal>

QVariantMap colorfulBuildInfo()
{
    return {
        {QStringLiteral("version"), QString::fromLatin1(COLORFUL_VERSION)},
        {QStringLiteral("commit"), QString::fromLatin1(COLORFUL_GIT_COMMIT)},
        {QStringLiteral("qt"), QString::fromLatin1(qVersion())},
        {QStringLiteral("mpv"), QString::fromLatin1(COLORFUL_MPV_VERSION)},
        {QStringLiteral("compiler"), QString::fromLatin1(__VERSION__)},
        {QStringLiteral("architecture"), QSysInfo::currentCpuArchitecture()},
        {QStringLiteral("system"), QSysInfo::prettyProductName()},
        {QStringLiteral("license"), QStringLiteral("GPL-3.0-or-later")},
    };
}
