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

    const auto partyOnly = DiscordPresence::buildActivity(
        QStringLiteral("Track"), QStringLiteral("Artist"), {}, {}, 0, 180000, true,
        {}, false, QStringLiteral("relay-session"), 1,
        QStringLiteral("https://colorful.valerie.sh/discord/join#v1.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"));
    const auto partyButtons = partyOnly.value(QStringLiteral("buttons")).toArray();
    if (partyButtons.size() != 1
        || partyButtons.first().toObject().value(QStringLiteral("label")).toString()
               != QStringLiteral("Join Party")
        || partyOnly.value(QStringLiteral("instance")).toBool() != true
        || partyOnly.value(QStringLiteral("party")).toObject().value(QStringLiteral("id")).toString()
               != QStringLiteral("relay-session")) return 1;

    const auto both = DiscordPresence::buildActivity(
        QStringLiteral("Track"), QStringLiteral("Artist"), {}, {}, 0, 180000, true,
        QStringLiteral("https://music.youtube.com/watch?v=abc%201"), true,
        QStringLiteral("relay-session"), 2,
        QStringLiteral("https://colorful.valerie.sh/discord/join#v1.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"));
    const auto bothButtons = both.value(QStringLiteral("buttons")).toArray();
    if (bothButtons.size() != 2
        || bothButtons.at(0).toObject().value(QStringLiteral("label")).toString() != QStringLiteral("View Track")
        || bothButtons.at(1).toObject().value(QStringLiteral("label")).toString() != QStringLiteral("Join Party")
        || both.value(QStringLiteral("party")).toObject().value(QStringLiteral("size")).toArray().size() != 2
        || both.value(QStringLiteral("party")).toObject().value(QStringLiteral("size")).toArray().at(0).toInt() != 2
        || both.value(QStringLiteral("party")).toObject().value(QStringLiteral("size")).toArray().at(1).toInt() != 64) return 1;

    const auto badScheme = DiscordPresence::buildActivity(
        QStringLiteral("Track"), QStringLiteral("Artist"), {}, {}, 0, 180000, true,
        {}, false, QStringLiteral("relay-session"), 2,
        QStringLiteral("http://colorful.valerie.sh/discord/join#v1.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"));
    const auto badQuery = DiscordPresence::buildActivity(
        QStringLiteral("Track"), QStringLiteral("Artist"), {}, {}, 0, 180000, true,
        {}, false, QStringLiteral("relay-session"), 2,
        QStringLiteral("https://colorful.valerie.sh/discord/join?x=1#v1.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"));
    if (!badScheme.value(QStringLiteral("buttons")).toArray().isEmpty()
        || !badQuery.value(QStringLiteral("buttons")).toArray().isEmpty()) return 1;

    const auto paused = DiscordPresence::buildActivity(
        QStringLiteral("Track"), QStringLiteral("Artist"), QStringLiteral("Album"), {}, 42, 180000, false,
        {}, false, QStringLiteral("relay-session"), 2, {});
    if (paused.value(QStringLiteral("details")).toString() != QStringLiteral("Track")
        || paused.value(QStringLiteral("state")).toString() != QStringLiteral("Artist · Paused")
        || paused.value(QStringLiteral("instance")).toBool() != true) return 1;

    const auto invalid = DiscordPresence::buildActivity(
        QStringLiteral("Track"), QStringLiteral("Artist"), {}, {}, 0, 180000, true,
        QStringLiteral("javascript:alert(1)"), true);
    return check(invalid, false);
}
