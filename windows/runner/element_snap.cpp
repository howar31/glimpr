#include "element_snap.h"

#include <uiautomation.h>

#include <winrt/base.h>

#include <cmath>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <utility>

#include "dpi_util.h"
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

// The first child of [parent] (control view, cached bounds) whose bounding
// rectangle contains [pt]; null when none does.
winrt::com_ptr<IUIAutomationElement> ChildAtPoint(
    IUIAutomationTreeWalker* walker, IUIAutomationCacheRequest* cache,
    IUIAutomationElement* parent, POINT pt) {
  winrt::com_ptr<IUIAutomationElement> child;
  if (FAILED(walker->GetFirstChildElementBuildCache(parent, cache,
                                                    child.put())) ||
      !child) {
    return nullptr;
  }
  for (int i = 0; child && i < kMaxSiblings; ++i) {
    RECT rc{};
    if (SUCCEEDED(child->get_CachedBoundingRectangle(&rc)) &&
        !IsRectEmpty(&rc) && PtInRect(&rc, pt)) {
      return child;
    }
    winrt::com_ptr<IUIAutomationElement> next;
    if (FAILED(walker->GetNextSiblingElementBuildCache(child.get(), cache,
                                                       next.put()))) {
      break;
    }
    child = std::move(next);
  }
  return nullptr;
}

struct Job {
  HMONITOR mon;
  double lx = 0, ly = 0;
  int walk = 0;
  std::vector<HWND> exclude;
  Host::Reply reply;
};

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
  if (!target) return std::nullopt;
  DWORD pid = 0;
  GetWindowThreadProcessId(target, &pid);
  // Our own window (Settings / editor / pin) on top: null -> Dart whole-window
  // snaps it (element-level snap inside our own windows is impossible, the
  // topmost overlay shadows our own tree -- the mac ruling carried over).
  if (pid == GetCurrentProcessId()) return std::nullopt;

  winrt::com_ptr<IUIAutomationElement> el;
  if (FAILED(ua->ElementFromHandleBuildCache(target, cache, el.put())) || !el) {
    return std::nullopt;
  }

  // Descend to the element at the point (the app-scoped hit test).
  for (int d = 0; d < kMaxDepth; ++d) {
    auto child = ChildAtPoint(walker, cache, el.get(), pt);
    if (!child) break;
    el = std::move(child);
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
      auto child = ChildAtPoint(walker, cache, el.get(), pt);
      if (!child) break;
      el = std::move(child);
      --applied;
    }
  }

  RECT rc{};
  if (FAILED(el->get_CachedBoundingRectangle(&rc)) || IsRectEmpty(&rc)) {
    return std::nullopt;
  }

  BSTR name = nullptr;
  el->get_CachedName(&name);
  const std::string title = Utf8FromBstr(name);
  if (name) SysFreeString(name);
  BSTR type = nullptr;
  el->get_CachedLocalizedControlType(&type);
  const std::string role = Utf8FromBstr(type);
  if (type) SysFreeString(type);

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
