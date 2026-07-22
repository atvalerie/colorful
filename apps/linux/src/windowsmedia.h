#pragma once

#include <QObject>
#include <memory>

class Backend;
class QWindow;

class WindowsMediaSession final : public QObject
{
public:
    WindowsMediaSession(Backend *backend, QWindow *window, QObject *parent = nullptr);
    ~WindowsMediaSession() override;

private:
    class Impl;
    std::unique_ptr<Impl> m_impl;
};
