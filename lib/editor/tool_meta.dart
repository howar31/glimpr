import 'package:flutter/material.dart';
import 'editor_controller.dart';

/// Canonical per-tool icon + display order, shared by the overlay toolbar and
/// the Shortcuts settings rows so the two never drift. Order = the toolbar
/// layout: the region tools (crop/blur/pixelate) first, then the drawing tools.
/// Canonical per-tool display name, shared by the Shortcuts settings rows and
/// the toolbar tooltips so the two always show the exact same wording. In pin
/// mode (capture-to-pin) the crop slot IS the pin region selector — same tool,
/// same key, different commit — so only its NAME follows [pinMode]; the
/// Settings row shows the combined form via [toolSettingsLabel].
String toolLabel(ToolKind t, {bool pinMode = false}) => switch (t) {
      ToolKind.crop => pinMode ? 'Pin' : 'Crop',
      ToolKind.blur => 'Blur',
      ToolKind.pixelate => 'Pixelate',
      ToolKind.rectangle => 'Rectangle',
      ToolKind.ellipse => 'Ellipse',
      ToolKind.line => 'Line',
      ToolKind.arrow => 'Arrow',
      ToolKind.pen => 'Pen',
      ToolKind.text => 'Text',
      ToolKind.highlighter => 'Highlighter',
      ToolKind.step => 'Numbered step',
      ToolKind.stamp => 'Image stamp',
      ToolKind.magnify => 'Magnify',
      ToolKind.spotlight => 'Spotlight',
      // The "paste" slot is the universal SELECT tool (select / move / resize
      // / delete any drawable); the paste ACTION is the Cmd-V "Paste image"
      // command.
      ToolKind.paste => 'Select',
    };

/// The Settings > Shortcuts row title. The crop slot's one binding drives both
/// contexts (crop normally, the pin region selector in pin mode), so its row
/// names both; every other tool matches [toolLabel] exactly.
String toolSettingsLabel(ToolKind t) =>
    t == ToolKind.crop ? 'Crop / Pin' : toolLabel(t);

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
  (ToolKind.magnify, Icons.zoom_in),
  (ToolKind.spotlight, Icons.center_focus_strong),
];
