import 'package:flutter/material.dart';
import 'editor_controller.dart';

/// Canonical per-tool icon + display order, shared by the overlay toolbar and
/// the Shortcuts settings rows so the two never drift. Order = the toolbar
/// layout: the region tools (crop/blur/pixelate) first, then the drawing tools.
const kEditorToolMeta = <(ToolKind, IconData)>[
  // The "paste" slot is the universal SELECT tool (any-type select/move/resize/
  // delete); the Cmd-V paste action drops images into it. Placed first as the
  // pointer/select tool, ahead of the region + drawing tools.
  (ToolKind.paste, Icons.ads_click),
  (ToolKind.crop, Icons.crop),
  (ToolKind.blur, Icons.blur_on),
  (ToolKind.pixelate, Icons.grid_on),
  (ToolKind.rectangle, Icons.crop_square),
  (ToolKind.ellipse, Icons.circle_outlined),
  (ToolKind.line, Icons.horizontal_rule),
  (ToolKind.arrow, Icons.north_east),
  (ToolKind.pen, Icons.gesture),
  (ToolKind.text, Icons.title),
  (ToolKind.highlighter, Icons.border_color),
  (ToolKind.step, Icons.looks_one),
  (ToolKind.stamp, Icons.add_photo_alternate),
];
