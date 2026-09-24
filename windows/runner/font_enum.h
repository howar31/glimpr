#ifndef RUNNER_FONT_ENUM_H_
#define RUNNER_FONT_ENUM_H_

#include <flutter/encodable_value.h>

// The installed font family names (an EncodableList of UTF-8 strings, sorted),
// cached for the process lifetime. Served on glimpr/fonts by the overlay and
// editor engines' text tool. Defined in overlay_manager.cpp.
flutter::EncodableValue EnumerateFontFamilies();

#endif  // RUNNER_FONT_ENUM_H_
