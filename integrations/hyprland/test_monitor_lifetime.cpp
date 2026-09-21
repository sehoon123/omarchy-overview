// Offline unit fixtures, never a Wayland client. Compile only via the runner.
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>
#include <hyprutils/memory/WeakPtr.hpp>
#include <hyprutils/memory/UniquePtr.hpp>
#include <hyprutils/signal/Signal.hpp>
#include <hyprutils/math/Box.hpp>
#include <gtest/gtest.h>

using namespace Hyprutils::Memory;
using namespace Hyprutils::Signal;
using namespace Hyprutils::Math;
template <typename T> using SP = CSharedPointer<T>;
template <typename T> using WP = CWeakPointer<T>;
template <typename T> using UP = CUniquePointer<T>;
#define UNLIKELY
#define LOGM(...) ((void)0)
using DRMFormat = uint32_t;
constexpr DRMFormat DRM_FORMAT_XRGB2101010 = 1, DRM_FORMAT_ARGB2101010 = 2, DRM_FORMAT_XBGR2101010 = 3;
namespace NFormatUtils { static DRMFormat alphaFormat(DRMFormat format) { return format; } }
namespace Render { class IFramebuffer {}; }
namespace Desktop::View { struct IGeometric { enum { GEOMETRIC_CURRENT }; }; }
namespace Screenshare { class CScreenshareFrame; class CCursorshareSession; }
struct wl_client {};
class CWLPointerResource;

struct TestMonitor {
    double m_scale = 1.0;
    Vector2D m_pixelSize = {1920, 1080};
    int m_transform = 0;
    std::string m_name = "test-output";
    struct { CSignalT<> disconnect, modeChanged; } m_events;
    DRMFormat getPreferredReadFormat() { return 4; }
};
using PHLMONITOR = SP<TestMonitor>;
using PHLMONITORREF = WP<TestMonitor>;
struct TestWindow {
    PHLMONITORREF m_monitor;
    bool m_isMapped = true;
    std::string m_title = "fixture";
    Vector2D dimensions = {640, 480};
    Vector2D size(int) { return dimensions; }
    struct { CSignalT<> unmap, resize, monitorChanged; } m_events;
};
using PHLWINDOW = SP<TestWindow>;
using PHLWINDOWREF = WP<TestWindow>;
struct TestMonitorState {
    std::vector<PHLMONITOR> monitors;
    bool contains(PHLMONITOR monitor) { return std::ranges::find(monitors, monitor) != monitors.end(); }
};
namespace State {
    static TestMonitorState* monitorState() { static TestMonitorState state; return &state; }
}
struct CEventLoopTimer {
    template <typename... Args> CEventLoopTimer(Args&&...) {}
};
struct TestLoop {
    int registrations = 0;
    void addTimer(SP<CEventLoopTimer>) { registrations++; }
};
static TestLoop loop;
static TestLoop* g_pEventLoopManager = &loop;
struct TestRenderer { bool m_directScanoutBlocked = false; };
static TestRenderer renderer;
static TestRenderer* g_pHyprRenderer = &renderer;

#include "production.inc"

using namespace Screenshare;
class MonitorLifetime : public ::testing::Test {
  protected:
    PHLMONITOR monitor;
    PHLWINDOW window;
    wl_client client;
    void SetUp() override {
        mgr() = makeUnique<CScreenshareManager>();
        monitor = makeShared<TestMonitor>();
        window = makeShared<TestWindow>();
        window->m_monitor = monitor;
        State::monitorState()->monitors = {monitor};
        loop.registrations = 0;
    }
    void TearDown() override {
        while (!mgr()->m_managedSessions.empty())
            mgr()->m_managedSessions.back()->m_session->stop();
        mgr() = nullptr;
        State::monitorState()->monitors.clear();
    }
};

TEST_F(MonitorLifetime, MissingSourcesStartStopped) {
    CScreenshareSession output(PHLMONITOR{}, &client);
    CScreenshareSession region(PHLMONITOR{}, CBox{}, &client);
    CScreenshareSession toplevel(PHLWINDOW{}, &client);
    EXPECT_FALSE(output.isActive());
    EXPECT_FALSE(region.isActive());
    EXPECT_FALSE(toplevel.isActive());
    EXPECT_EQ(loop.registrations, 0);
}

TEST_F(MonitorLifetime, InitializationWithoutMonitorDoesNotAllocateCapture) {
    window->m_monitor.reset();
    CScreenshareSession session(window, &client);
    EXPECT_FALSE(session.isActive());
    EXPECT_TRUE(session.allowedFormats().empty());
    EXPECT_FALSE(session.m_shareStopTimer);
    EXPECT_EQ(loop.registrations, 0);
}

TEST_F(MonitorLifetime, FactoriesRejectUnavailableSources) {
    EXPECT_FALSE(mgr()->newSession(&client, PHLWINDOW{}));
    EXPECT_FALSE(mgr()->getManagedSession(&client, PHLWINDOW{}));
    EXPECT_FALSE(mgr()->getManagedSession(&client, PHLMONITOR{}));
    EXPECT_FALSE(mgr()->getManagedSession(&client, PHLMONITOR{}, CBox{}));
    window->m_monitor.reset();
    EXPECT_FALSE(mgr()->newSession(&client, window));
    EXPECT_FALSE(mgr()->getManagedSession(&client, window));
    window->m_monitor = monitor;
    window->m_isMapped = false;
    EXPECT_FALSE(mgr()->getManagedSession(&client, window));
    window->m_isMapped = true;
    State::monitorState()->monitors.clear();
    EXPECT_FALSE(mgr()->getManagedSession(&client, window));
    EXPECT_FALSE(mgr()->getManagedSession(&client, monitor));
    EXPECT_FALSE(mgr()->getManagedSession(&client, monitor, CBox{0, 0, 100, 100}));
    EXPECT_TRUE(mgr()->m_managedSessions.empty());
    EXPECT_TRUE(mgr()->m_sessions.empty());
    EXPECT_EQ(loop.registrations, 0);
}

TEST_F(MonitorLifetime, HealthyWindowAndOutputSessionsRemainReusable) {
    auto first = mgr()->getManagedSession(&client, window);
    auto second = mgr()->getManagedSession(&client, window);
    ASSERT_TRUE(first);
    EXPECT_EQ(first, second);
    EXPECT_TRUE(first->isActive());
    EXPECT_EQ(first->bufferSize(), window->dimensions);
    EXPECT_EQ(mgr()->m_sessions.size(), 1U);
    EXPECT_EQ(mgr()->m_managedSessions.size(), 1U);
    EXPECT_TRUE(mgr()->getManagedSession(&client, monitor));
    EXPECT_TRUE(mgr()->getManagedSession(&client, monitor, CBox{0, 0, 100, 100}));
    EXPECT_EQ(mgr()->m_sessions.size(), 3U);
}

TEST_F(MonitorLifetime, MonitorLossStopsOnceWithoutConstraintsNotification) {
    auto session = mgr()->newSession(&client, window);
    ASSERT_TRUE(session);
    int stopped = 0, constraints = 0;
    auto stop = session->m_events.stopped.listen([&] { stopped++; });
    auto update = session->m_events.constraintsChanged.listen([&] { constraints++; });
    window->m_monitor.reset();
    window->m_events.monitorChanged.emit();
    EXPECT_FALSE(session->isActive());
    window->m_events.resize.emit();
    window->m_events.monitorChanged.emit();
    monitor->m_events.modeChanged.emit();
    monitor->m_events.disconnect.emit();
    EXPECT_EQ(stopped, 1);
    EXPECT_EQ(constraints, 0);
}

TEST_F(MonitorLifetime, ResizeAfterMonitorLossDoesNotUseDestroyedManagedSession) {
    auto session = mgr()->getManagedSession(&client, window);
    ASSERT_TRUE(session);
    int updates = 0;
    auto listener = session->m_events.constraintsChanged.listen([&] { updates++; });
    window->m_monitor.reset();
    window->m_events.resize.emit();
    EXPECT_TRUE(session.expired());
    EXPECT_TRUE(mgr()->m_managedSessions.empty());
    EXPECT_EQ(updates, 0);
}

TEST_F(MonitorLifetime, ModeChangeAfterMonitorLossDoesNotUseDestroyedManagedSession) {
    auto session = mgr()->getManagedSession(&client, window);
    ASSERT_TRUE(session);
    window->m_monitor.reset();
    monitor->m_events.modeChanged.emit();
    EXPECT_TRUE(session.expired());
    EXPECT_TRUE(mgr()->m_managedSessions.empty());
}

TEST_F(MonitorLifetime, MonitorReassignmentUpdatesListenersAndConstraints) {
    auto session = mgr()->newSession(&client, window);
    auto next = makeShared<TestMonitor>();
    next->m_scale = 2.0;
    window->m_monitor = next;
    window->m_events.monitorChanged.emit();
    ASSERT_TRUE(session->isActive());
    EXPECT_EQ(session->monitor(), next);
    EXPECT_EQ(session->bufferSize(), window->dimensions * 2.0);
    monitor->m_events.disconnect.emit();
    EXPECT_TRUE(session->isActive());
    next->m_events.disconnect.emit();
    EXPECT_FALSE(session->isActive());
}

TEST_F(MonitorLifetime, ManagedSessionIsRemovedAndCanBeCreatedAfterRecovery) {
    auto old = mgr()->getManagedSession(&client, window);
    ASSERT_TRUE(old);
    window->m_monitor.reset();
    window->m_events.monitorChanged.emit();
    EXPECT_TRUE(old.expired());
    EXPECT_TRUE(mgr()->m_managedSessions.empty());
    window->m_monitor = monitor;
    auto recovered = mgr()->getManagedSession(&client, window);
    ASSERT_TRUE(recovered);
    EXPECT_TRUE(recovered->isActive());
    EXPECT_EQ(recovered->bufferSize(), window->dimensions);
    EXPECT_EQ(mgr()->m_managedSessions.size(), 1U);
}

TEST_F(MonitorLifetime, RemovingFirstManagedSessionKeepsOtherSessionsAlive) {
    auto first = mgr()->getManagedSession(&client, window);
    auto output = mgr()->getManagedSession(&client, monitor);
    auto region = mgr()->getManagedSession(&client, monitor, CBox{0, 0, 100, 100});
    ASSERT_TRUE(first);
    ASSERT_TRUE(output);
    ASSERT_TRUE(region);
    window->m_monitor.reset();
    window->m_events.monitorChanged.emit();
    EXPECT_TRUE(first.expired());
    EXPECT_TRUE(output->isActive());
    EXPECT_TRUE(region->isActive());
    EXPECT_EQ(mgr()->m_managedSessions.size(), 2U);
}

TEST_F(MonitorLifetime, StoppedSessionCannotResumeOnLateMetadata) {
    auto session = mgr()->newSession(&client, window);
    int updates = 0;
    auto listener = session->m_events.constraintsChanged.listen([&] { updates++; });
    session->stop();
    window->m_events.monitorChanged.emit();
    window->m_events.resize.emit();
    monitor->m_events.modeChanged.emit();
    EXPECT_FALSE(session->isActive());
    EXPECT_EQ(updates, 0);
}
