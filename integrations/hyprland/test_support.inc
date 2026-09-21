// Test-only rendering boundaries. The generated declarations above and the
// implementation bodies below come directly from the patched source tree.
namespace Screenshare {
    class CScreenshareFrame {
      public:
        CScreenshareFrame(WP<CScreenshareSession>, bool, bool) {}
        WP<CScreenshareFrame> m_self;
    };
    class CCursorshareSession {};
    CScreenshareManager::CScreenshareManager() {}
    UP<CScreenshareManager>& mgr() {
        static UP<CScreenshareManager> manager;
        return manager;
    }
}
