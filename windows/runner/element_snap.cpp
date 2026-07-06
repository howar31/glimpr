#include "element_snap.h"

#include <oleacc.h>
#include <uiautomation.h>

#include <winrt/base.h>

#include <cmath>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_set>
#include <utility>

#include "dpi_util.h"
#include "perf_log.h"
#include "record_clock.h"
#include "utils.h"
#include "window_enum.h"

namespace elsnap {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// Climb out of sub-minimum noise (text runs, separators) to the first
// sensibly-sized element -- the mac path's kMinSide, in LOGICAL units.
constexpr double kMinSideLogical = 24.0;

// Descent/climb guards: no real UIA tree is this deep or wide at one level,
// but a broken provider could loop.
constexpr int kMaxDepth = 64;
constexpr int kMaxSiblings = 512;

std::string Utf8FromBstr(BSTR s) {
  if (!s) return {};
  return Utf8FromUtf16(std::wstring(s, SysStringLen(s)));
}

// The SMALLEST child of [parent] (control view, cached bounds) whose bounding
// rectangle contains [pt]; null when none does. Smallest = most specific:
// siblings can overlap (e.g. Chrome's client-wide "Intermediate D3D Window"
// pane overlaps the page's render-host child) and the first-in-tree-order one
// may be the coarse cover, which would end the descent one level too early.
// [include_offscreen]: the auto descent stays strict (never frame something
// invisible), but an EXPLICIT walk-down admits offscreen-flagged candidates --
// Gecko flags even visible containers offscreen generously, and the user is
// looking at the frame and can judge (owner design, 2026-07-06).
winrt::com_ptr<IUIAutomationElement> ChildAtPoint(
    IUIAutomationTreeWalker* walker, IUIAutomationCacheRequest* cache,
    IUIAutomationElement* parent, POINT pt, bool include_offscreen = false) {
  winrt::com_ptr<IUIAutomationElement> child;
  if (FAILED(walker->GetFirstChildElementBuildCache(parent, cache,
                                                    child.put())) ||
      !child) {
    return nullptr;
  }
  winrt::com_ptr<IUIAutomationElement> best;
  LONG64 best_area = 0;
  for (int i = 0; child && i < kMaxSiblings; ++i) {
    // Skip elements that exist in the tree but are not actually shown (a
    // closed menu keeps stale bounds, for instance) -- they hit-test smaller
    // than the real content and would win the specificity rule with a frame
    // that visibly matches nothing.
    BOOL offscreen = FALSE;
    RECT rc{};
    if ((include_offscreen ||
         FAILED(child->get_CachedIsOffscreen(&offscreen)) || !offscreen) &&
        SUCCEEDED(child->get_CachedBoundingRectangle(&rc)) &&
        !IsRectEmpty(&rc) && PtInRect(&rc, pt)) {
      const LONG64 area = static_cast<LONG64>(rc.right - rc.left) *
                          (rc.bottom - rc.top);
      if (!best || area < best_area) {
        best = child;
        best_area = area;
      }
    }
    winrt::com_ptr<IUIAutomationElement> next;
    if (FAILED(walker->GetNextSiblingElementBuildCache(child.get(), cache,
                                                       next.put()))) {
      break;
    }
    child = std::move(next);
  }
  return best;
}

struct Job {
  HMONITOR mon;
  double lx = 0, ly = 0;
  int walk = 0;
  std::vector<HWND> exclude;
  Host::Reply reply;
};

// Browsers keep their accessibility tree DORMANT until an assistive-technology
// client announces itself. The classic signal both Gecko and Chromium listen
// for is an MSAA OBJID_CLIENT request on the window that owns the content
// (Gecko: the top-level; Chromium: the render-host child, which our scoped
// ElementFromHandle already touches). Fire it once per top-level window; the
// tree materializes asynchronously, so the 30 Hz hover naturally picks it up
// a beat later.
void WakeAccessibility(HWND hwnd) {
  static thread_local std::unordered_set<HWND> woken;
  if (!woken.insert(hwnd).second) return;
  IAccessible* acc = nullptr;
  if (SUCCEEDED(AccessibleObjectFromWindow(
          hwnd, static_cast<DWORD>(OBJID_CLIENT), IID_IAccessible,
          reinterpret_cast<void**>(&acc))) &&
      acc) {
    acc->Release();
  }
}

// One query, on the worker thread. Null = fall back to window snap.
std::optional<EncodableMap> RunQuery(IUIAutomation* ua,
                                     IUIAutomationTreeWalker* walker,
                                     IUIAutomationCacheRequest* cache,
                                     const Job& job) {
  const int64_t t0 = Qpc100ns();

  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  if (!GetMonitorInfo(job.mon, &mi)) return std::nullopt;
  const double scale = MonitorScale(job.mon);
  const POINT pt{
      mi.rcMonitor.left + static_cast<LONG>(std::lround(job.lx * scale)),
      mi.rcMonitor.top + static_cast<LONG>(std::lround(job.ly * scale))};

  // The frontmost real window under the point, never our own overlay. A global
  // UIA ElementFromPoint would hit OUR topmost overlay instead -- scope the
  // query to this window's tree.
  HWND target = win_enum::TopWindowAt(pt, job.exclude);
  if (!target) {
    perf::Mark("elsnapDbg noTarget");
    return std::nullopt;
  }
  DWORD pid = 0;
  GetWindowThreadProcessId(target, &pid);
  // Our own window (Settings / editor / pin) on top: null -> Dart whole-window
  // snaps it (element-level snap inside our own windows is impossible, the
  // topmost overlay shadows our own tree -- the mac ruling carried over).
  if (pid == GetCurrentProcessId()) return std::nullopt;

  // Descend the HWND layer first: the SMALLEST visible descendant window
  // containing the point (ShareX's control-detection granularity is exactly
  // these child windows; smallest = most specific, the same rule the snap
  // list uses). Input-style hit tests (ChildWindowFromPointEx) do NOT work
  // here: e.g. BOTH of Chrome's big children -- the client-wide "Intermediate
  // D3D Window" cover and the page's Chrome_RenderWidgetHostHWND -- are
  // WS_EX_TRANSPARENT (input goes to the top-level), and the UIA element tree
  // does not expose the page child while the app's accessibility is dormant.
  // Starting the element query AT the page child gives the page rect as the
  // floor, and its own subtree once accessibility wakes.
  struct HwndHit {
    POINT pt;
    HWND best;
    LONG64 best_area;
  } hit{pt, nullptr, 0};
  EnumChildWindows(
      target,
      [](HWND child, LPARAM lp) -> BOOL {
        auto* h = reinterpret_cast<HwndHit*>(lp);
        if (!IsWindowVisible(child)) return TRUE;
        RECT r{};
        if (!GetWindowRect(child, &r) || IsRectEmpty(&r)) return TRUE;
        if (!PtInRect(&r, h->pt)) return TRUE;
        const LONG64 area =
            static_cast<LONG64>(r.right - r.left) * (r.bottom - r.top);
        if (!h->best || area < h->best_area) {
          h->best = child;
          h->best_area = area;
        }
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&hit));
  const HWND hwnd = hit.best ? hit.best : target;
  WakeAccessibility(target);

  winrt::com_ptr<IUIAutomationElement> el;
  if (FAILED(ua->ElementFromHandleBuildCache(hwnd, cache, el.put())) || !el) {
    perf::Mark("elsnapDbg noRoot");
    return std::nullopt;
  }

  // Then descend the element tree to the point (the app-scoped hit test).
  int depth = 0;
  for (int d = 0; d < kMaxDepth; ++d) {
    auto child = ChildAtPoint(walker, cache, el.get(), pt);
    if (!child) break;
    el = std::move(child);
    ++depth;
  }

  // A bare child-window pane (no elements inside) does not always mean there
  // is nothing finer: Gecko hangs its whole web tree off the TOP-LEVEL
  // element, not off the compositor child the HWND scoping picked. Retry from
  // the top level and keep whichever result is more specific (smaller).
  if (depth == 0 && hwnd != target) {
    winrt::com_ptr<IUIAutomationElement> root;
    if (SUCCEEDED(ua->ElementFromHandleBuildCache(target, cache,
                                                  root.put())) &&
        root) {
      int root_depth = 0;
      for (int d = 0; d < kMaxDepth; ++d) {
        auto child = ChildAtPoint(walker, cache, root.get(), pt);
        if (!child) break;
        root = std::move(child);
        ++root_depth;
      }
      RECT child_rc{}, root_rc{};
      if (root_depth > 0 &&
          SUCCEEDED(el->get_CachedBoundingRectangle(&child_rc)) &&
          SUCCEEDED(root->get_CachedBoundingRectangle(&root_rc)) &&
          !IsRectEmpty(&root_rc)) {
        const LONG64 child_area =
            static_cast<LONG64>(child_rc.right - child_rc.left) *
            (child_rc.bottom - child_rc.top);
        const LONG64 root_area =
            static_cast<LONG64>(root_rc.right - root_rc.left) *
            (root_rc.bottom - root_rc.top);
        if (IsRectEmpty(&child_rc) || root_area < child_area) {
          el = std::move(root);
          depth = root_depth;
        }
      }
    }
  }

  // Climb out of sub-minimum noise to the first sensibly-sized element.
  const double min_px = kMinSideLogical * scale;
  for (int i = 0; i < kMaxDepth; ++i) {
    RECT rc{};
    if (FAILED(el->get_CachedBoundingRectangle(&rc))) break;
    if (rc.right - rc.left >= min_px && rc.bottom - rc.top >= min_px) break;
    winrt::com_ptr<IUIAutomationElement> parent;
    if (FAILED(walker->GetParentElementBuildCache(el.get(), cache,
                                                  parent.put())) ||
        !parent) {
      break;
    }
    el = std::move(parent);
  }

  // Apply the tree walk, counting how many levels ACTUALLY moved (it stops at
  // the real root/leaf). Dart syncs its counter to this so it can't overshoot
  // the real tree depth.
  int applied = 0;
  if (job.walk > 0) {
    for (int i = 0; i < job.walk; ++i) {
      winrt::com_ptr<IUIAutomationElement> parent;
      if (FAILED(walker->GetParentElementBuildCache(el.get(), cache,
                                                    parent.put())) ||
          !parent) {
        break;
      }
      // Stop at the window root: climbing past it would jump to the desktop.
      RECT prc{};
      if (FAILED(parent->get_CachedBoundingRectangle(&prc)) ||
          IsRectEmpty(&prc)) {
        break;
      }
      el = std::move(parent);
      ++applied;
    }
  } else if (job.walk < 0) {
    for (int i = 0; i < -job.walk; ++i) {
      auto child =
          ChildAtPoint(walker, cache, el.get(), pt, /*include_offscreen=*/true);
      if (!child) break;
      el = std::move(child);
      --applied;
    }
  }

  RECT rc{};
  if (FAILED(el->get_CachedBoundingRectangle(&rc)) || IsRectEmpty(&rc)) {
    perf::Mark("elsnapDbg noRect depth=" + std::to_string(depth));
    return std::nullopt;
  }
  // Web content can report UNCLIPPED layout bounds (an image wider than the
  // viewport); the user can only mean the visible part, so clip to the window
  // that hosts the element.
  RECT host{};
  if (GetWindowRect(hwnd, &host)) {
    RECT clipped{};
    if (!IntersectRect(&clipped, &rc, &host)) {
      perf::Mark("elsnapDbg offscreen depth=" + std::to_string(depth));
      return std::nullopt;
    }
    rc = clipped;
  }

  BSTR name = nullptr;
  el->get_CachedName(&name);
  const std::string title = Utf8FromBstr(name);
  if (name) SysFreeString(name);
  BSTR type = nullptr;
  el->get_CachedLocalizedControlType(&type);
  const std::string role = Utf8FromBstr(type);
  if (type) SysFreeString(type);

  if (perf::Enabled()) {
    wchar_t cls[128] = L"";
    GetClassNameW(target, cls, 128);
    perf::Mark("elsnapDbg pt=" + std::to_string(pt.x) + "," +
               std::to_string(pt.y) + " target=" + Utf8FromUtf16(cls) + "/" +
               win_enum::ProcessName(target) + " depth=" +
               std::to_string(depth) + " role=" + role + " rect=" +
               std::to_string(rc.left) + "," + std::to_string(rc.top) + "," +
               std::to_string(rc.right - rc.left) + "x" +
               std::to_string(rc.bottom - rc.top));
  }

  const auto logical = [&](LONG v, LONG origin) {
    return (static_cast<double>(v) - origin) / scale;
  };
  EncodableMap out;
  out[EncodableValue("x")] = EncodableValue(logical(rc.left, mi.rcMonitor.left));
  out[EncodableValue("y")] = EncodableValue(logical(rc.top, mi.rcMonitor.top));
  out[EncodableValue("w")] =
      EncodableValue(static_cast<double>(rc.right - rc.left) / scale);
  out[EncodableValue("h")] =
      EncodableValue(static_cast<double>(rc.bottom - rc.top) / scale);
  out[EncodableValue("role")] = EncodableValue(role);
  out[EncodableValue("title")] = EncodableValue(title);
  out[EncodableValue("app")] = EncodableValue(win_enum::ProcessName(target));
  out[EncodableValue("latencyUs")] =
      EncodableValue(static_cast<int64_t>((Qpc100ns() - t0) / 10));
  out[EncodableValue("appliedWalk")] = EncodableValue(applied);
  // Owning window: current bounds + id, keyed back to the freeze-time
  // SnapWindow (windowNumber == HWND on Windows) for the divergence metric.
  const RECT wr = win_enum::VisibleWindowBounds(target);
  out[EncodableValue("winX")] =
      EncodableValue(logical(wr.left, mi.rcMonitor.left));
  out[EncodableValue("winY")] =
      EncodableValue(logical(wr.top, mi.rcMonitor.top));
  out[EncodableValue("winW")] =
      EncodableValue(static_cast<double>(wr.right - wr.left) / scale);
  out[EncodableValue("winH")] =
      EncodableValue(static_cast<double>(wr.bottom - wr.top) / scale);
  out[EncodableValue("windowId")] =
      EncodableValue(static_cast<int64_t>(reinterpret_cast<intptr_t>(target)));
  return out;
}

}  // namespace

struct Host::Impl {
  std::thread worker;
  std::mutex mutex;
  std::condition_variable cv;
  std::deque<Job> jobs;
  bool quit = false;

  void Run() {
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
    } catch (...) {
    }
    winrt::com_ptr<IUIAutomation> ua;
    winrt::com_ptr<IUIAutomationTreeWalker> walker;
    winrt::com_ptr<IUIAutomationCacheRequest> cache;
    if (SUCCEEDED(CoCreateInstance(__uuidof(CUIAutomation), nullptr,
                                   CLSCTX_INPROC_SERVER,
                                   __uuidof(IUIAutomation), ua.put_void()))) {
      // Bound every provider round-trip so a hung target app degrades to a
      // null reply (window-snap fallback) instead of stalling the queue --
      // the mac path's 120 ms AX messaging timeout, best effort (Win8.1+).
      if (auto ua2 = ua.try_as<IUIAutomation2>()) {
        ua2->put_ConnectionTimeout(1000);
        ua2->put_TransactionTimeout(250);
      }
      ua->get_ControlViewWalker(walker.put());
      if (SUCCEEDED(ua->CreateCacheRequest(cache.put())) && cache) {
        cache->AddProperty(UIA_BoundingRectanglePropertyId);
        cache->AddProperty(UIA_NamePropertyId);
        cache->AddProperty(UIA_LocalizedControlTypePropertyId);
        cache->AddProperty(UIA_IsOffscreenPropertyId);
      }
    }

    for (;;) {
      Job job;
      {
        std::unique_lock<std::mutex> lock(mutex);
        cv.wait(lock, [this] { return quit || !jobs.empty(); });
        if (quit && jobs.empty()) break;
        job = std::move(jobs.front());
        jobs.pop_front();
      }
      std::optional<EncodableMap> reply;
      if (ua && walker && cache) {
        try {
          reply = RunQuery(ua.get(), walker.get(), cache.get(), job);
        } catch (...) {
          reply = std::nullopt;
        }
      }
      job.reply(std::move(reply));
    }
    winrt::uninit_apartment();
  }
};

Host::Host() : impl_(new Impl) {
  impl_->worker = std::thread([this] { impl_->Run(); });
}

Host::~Host() {
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->quit = true;
  }
  impl_->cv.notify_all();
  if (impl_->worker.joinable()) impl_->worker.join();
  delete impl_;
}

void Host::Query(HMONITOR mon, double logical_x, double logical_y, int walk,
                 std::vector<HWND> exclude, Reply reply) {
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    Job job;
    job.mon = mon;
    job.lx = logical_x;
    job.ly = logical_y;
    job.walk = walk;
    job.exclude = std::move(exclude);
    job.reply = std::move(reply);
    impl_->jobs.push_back(std::move(job));
  }
  impl_->cv.notify_one();
}

}  // namespace elsnap
