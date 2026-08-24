#include "discordpresence.h"

#include <QCoreApplication>
#include <QJsonArray>
#include <QJsonObject>

namespace {
int check(const QJsonObject &activity, bool expectButton)
{
    const auto buttons = activity.value(QStringLiteral("buttons")).toArray();
    if (expectButton && (buttons.size() != 1
                         || buttons.first().toObject().value(QStringLiteral("label")).toString()
                                != QStringLiteral("View Track")
                         || buttons.first().toObject().value(QStringLiteral("url")).toString()
                                != QStringLiteral("https://music.youtube.com/watch?v=abc%201")))
        return 1;
    if (!expectButton && !buttons.isEmpty()) return 1;
    return 0;
}
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    const auto valid = DiscordPresence::buildActivity(
        QStringLiteral("Track"), QStringLiteral("Artist"), {}, {}, 0, 180000, true,
        QStringLiteral("https://music.youtube.com/watch?v=abc%201"), true);
    if (check(valid, true) != 0) return 1;

    const auto disabled = DiscordPresence::buildActivity(
        QStringLiteral("Track"), QStringLiteral("Artist"), {}, {}, 0, 180000, true,
        QStringLiteral("https://music.youtube.com/watch?v=abc%201"), false);
    if (check(disabled, false) != 0) return 1;

    const auto invalid = DiscordPresence::buildActivity(
        QStringLiteral("Track"), QStringLiteral("Artist"), {}, {}, 0, 180000, true,
        QStringLiteral("javascript:alert(1)"), true);
    return check(invalid, false);
}
