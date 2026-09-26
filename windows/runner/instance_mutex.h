#ifndef RUNNER_INSTANCE_MUTEX_H_
#define RUNNER_INSTANCE_MUTEX_H_

// The single-instance mutex (app_identity.h names it per build identity).
// Owned for the life of the main process, with one exception: the
// self-update releases it just before launching the installer, because the
// installer's AppMutex check refuses to run while the mutex exists, and takes
// it back when the user declines the elevation prompt.
namespace instance_mutex {

// Creates the mutex; true when another instance already holds it.
bool AcquireOrDetect();

// Drops the mutex (closes the only handle) so the installer may start.
void Release();

// Re-creates the mutex after a declined update (best effort).
void Reacquire();

}  // namespace instance_mutex

#endif  // RUNNER_INSTANCE_MUTEX_H_
