#include "buildinfo.h"
#include "buildinfo_generated.h"

#include <QSysInfo>
#include <QtGlobal>

QVariantMap colorfulBuildInfo()
{
#if defined(Q_OS_WIN)
    const auto platform = QStringLiteral("windows");
#elif defined(Q_OS_LINUX)
    const auto platform = QStringLiteral("linux");
#else
    const auto platform = QStringLiteral("desktop");
#endif
    return {
        {QStringLiteral("version"), QString::fromLatin1(COLORFUL_VERSION)},
        {QStringLiteral("commit"), QString::fromLatin1(COLORFUL_GIT_COMMIT)},
        {QStringLiteral("qt"), QString::fromLatin1(qVersion())},
        {QStringLiteral("mpv"), QString::fromLatin1(COLORFUL_MPV_VERSION)},
        {QStringLiteral("compiler"), QString::fromLatin1(__VERSION__)},
        {QStringLiteral("architecture"), QSysInfo::currentCpuArchitecture()},
        {QStringLiteral("system"), QSysInfo::prettyProductName()},
        {QStringLiteral("platform"), platform},
        {QStringLiteral("license"), QStringLiteral("GPL-3.0-or-later")},
    };
}
