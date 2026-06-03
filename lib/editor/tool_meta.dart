import 'package:flutter/material.dart';
import 'editor_controller.dart';

/// Canonical per-tool icon + display order, shared by the overlay toolbar and
/// the Shortcuts settings rows so the two never drift. Order = the toolbar
/// layout: the region tools (crop/blur/pixelate) first, then the drawing tools.
const kEditorToolMeta = <(ToolKind, IconData)>[
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
  (ToolKind.paste, Icons.content_paste),
];
