#ifndef RUNNER_COM_PTR_LITE_H_
#define RUNNER_COM_PTR_LITE_H_

// Minimal COM smart-release helper for the winrt-free recording files
// (record_audio / record_gif). Releases on scope exit. Everything else in the
// runner uses winrt::com_ptr.
template <typename T>
struct ComPtr {
  T* p = nullptr;
  ~ComPtr() {
    if (p) p->Release();
  }
  T** put() { return &p; }
  T* get() const { return p; }
  T* operator->() const { return p; }
  explicit operator bool() const { return p != nullptr; }
};

#endif  // RUNNER_COM_PTR_LITE_H_
