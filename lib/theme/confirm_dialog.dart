import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../l10n/gen/app_localizations.dart';
import 'glimpr_controls.dart';
import 'glimpr_theme.dart';

/// Shared Aurora-styled "discard?" confirmation. Frosted-glass card matching the
/// toolbar (blur + tint + border), a Cancel (ghost) + a confirm (accent) button.
/// Returns true to proceed (discard), false to cancel / dismiss. Used by both the
/// capture overlay (exit) and the standalone image editor (close / replace).
/// Null texts resolve to the localized defaults from [context].
Future<bool> showDiscardConfirm(
  BuildContext context, {
  String? title,
  String? message,
  String? confirmLabel,
  String? cancelLabel,
}) async {
  final l10n = AppLocalizations.of(context);
  // Locals (not the parameters): the dialog builder closure below blocks
  // parameter type promotion.
  final rTitle = title ?? l10n.confirmDiscardTitle;
  final rMessage = message ?? l10n.confirmDiscardMessage;
  final rConfirm = confirmLabel ?? l10n.confirmDiscard;
  final rCancel = cancelLabel ?? l10n.confirmCancel;
  final brightness =
      WidgetsBinding.instance.platformDispatcher.platformBrightness;
  final t = GlimprTokens.forBrightness(brightness);
  final dark = brightness == Brightness.dark;
  final result = await showDialog<bool>(
    context: context,
    barrierColor: const Color(0x99000000),
    builder: (c) => GlimprTheme(
      tokens: t,
      child: Center(
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: dark
                        ? const Color(0xF2161A24)
                        : const Color(0xF2EEF2F7),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: dark
                          ? const Color(0x33FFFFFF)
                          : const Color(0x66FFFFFF),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rTitle,
                        style: GlimprType.sansStyle(18, 700, t.fg1,
                            letterSpacing: -0.3),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        rMessage,
                        style: GlimprType.sansStyle(13.5, 400, t.fg3,
                            height: 1.45),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          GhostButton(rCancel,
                              onTap: () => Navigator.of(c).pop(false)),
                          const SizedBox(width: 10),
                          AccentButton(rConfirm,
                              onTap: () => Navigator.of(c).pop(true)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return result ?? false;
}
