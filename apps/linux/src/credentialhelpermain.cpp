#include "credentialstore.h"

#include <QCoreApplication>
#include <QFile>
#include <cstdio>

int main(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("colorful"));
    QCoreApplication::setOrganizationName(QStringLiteral("colorful"));
    const auto arguments = app.arguments();
    if (arguments.size() != 3) return 64;
    const auto action = arguments.at(1);
    const auto name = QStringLiteral("provider/") + arguments.at(2);
    QString error;
    if (action == QStringLiteral("load")) {
        const auto value = loadCredential(name, &error);
        if (!error.isEmpty()) {
            std::fprintf(stderr, "%s\n", error.toUtf8().constData());
            return 1;
        }
        QFile output;
        if (!output.open(stdout, QIODevice::WriteOnly)) return 1;
        return output.write(value) == value.size() ? 0 : 1;
    }
    if (action == QStringLiteral("save")) {
        QFile input;
        if (!input.open(stdin, QIODevice::ReadOnly)) return 1;
        if (saveCredential(name, input.readAll(), &error)) return 0;
        std::fprintf(stderr, "%s\n", error.toUtf8().constData());
        return 1;
    }
    if (action == QStringLiteral("delete")) {
        if (deleteCredential(name, &error)) return 0;
        std::fprintf(stderr, "%s\n", error.toUtf8().constData());
        return 1;
    }
    return 64;
}
