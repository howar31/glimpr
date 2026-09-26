#include "instance_mutex.h"

#include <windows.h>

#include "app_identity.h"

namespace instance_mutex {

namespace {
HANDLE g_mutex = nullptr;
}  // namespace

bool AcquireOrDetect() {
  g_mutex = ::CreateMutexW(nullptr, TRUE, GLIMPR_MUTEX_NAME_W);
  return g_mutex && ::GetLastError() == ERROR_ALREADY_EXISTS;
}

void Release() {
  if (!g_mutex) return;
  ::CloseHandle(g_mutex);
  g_mutex = nullptr;
}

void Reacquire() {
  if (g_mutex) return;
  g_mutex = ::CreateMutexW(nullptr, TRUE, GLIMPR_MUTEX_NAME_W);
}

}  // namespace instance_mutex
