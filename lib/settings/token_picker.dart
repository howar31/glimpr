import 'package:flutter/material.dart';
import '../l10n/gen/app_localizations.dart';
import '../output/name_tokens.dart';
import '../theme/glimpr_theme.dart';

/// "Insert variable" button for a pattern field. Opens a categorised menu built
/// from [kNameTokens] (every token shown with its `%` literal + a localised
/// description); selecting one inserts it at the field's cursor and re-focuses.
class TokenInsertButton extends StatelessWidget {
  final GlimprTokens t;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;

  const TokenInsertButton({
    super.key,
    required this.t,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Icon-only, field-height bordered box (the parent Row stretches it to the
    // TextField's height) — matches the adjacent Reset button; label in tooltip.
    return InkWell(
      onTap: () => _open(context, l),
      borderRadius: BorderRadius.circular(9),
      child: Tooltip(
        message: l.settingsInsertVariable,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: t.fieldBg,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: t.fieldBorder),
          ),
          child: Icon(Icons.add, size: 16, color: t.fg2),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, AppLocalizations l) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null) return;
    // Anchor the menu's top-left just below the button (opens downward).
    final at = box.localToGlobal(Offset(0, box.size.height + 2),
        ancestor: overlayBox);

    final items = <PopupMenuEntry<String>>[];
    TokenCategory? cat;
    for (final tok in kNameTokens) {
      if (tok.category != cat) {
        if (items.isNotEmpty) items.add(const PopupMenuDivider(height: 8));
        cat = tok.category;
        items.add(_header(_catLabel(l, cat)));
      }
      items.add(_tokenItem(tok, _desc(l, tok.token)));
    }

    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
      popUpAnimationStyle: AnimationStyle.noAnimation,
      color: t.menuBg,
      constraints: const BoxConstraints(maxWidth: 380),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GlimprTokens.radiusMenu),
        side: BorderSide(color: t.hudBorder),
      ),
      items: items,
    );
    if (picked != null) _insert(picked);
  }

  void _insert(String token) {
    final text = controller.text;
    final sel = controller.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final next = text.replaceRange(start, end, token);
    final caret = start + token.length;
    controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: caret),
    );
    onChanged(next);
    focusNode.requestFocus();
    // Re-assert the collapsed caret AFTER focus settles, so the field's
    // select-all-on-focus does not reselect everything — lets the user insert
    // several variables in a row.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.text == next) {
        controller.selection = TextSelection.collapsed(offset: caret);
      }
    });
  }

  PopupMenuItem<String> _header(String label) => PopupMenuItem<String>(
        enabled: false,
        height: 24,
        child: Text(label.toUpperCase(),
            style: GlimprType.sansStyle(10.5, 700, t.fg4)),
      );

  PopupMenuItem<String> _tokenItem(NameToken tok, String desc) =>
      PopupMenuItem<String>(
        value: tok.token,
        height: 36,
        child: Row(
          children: [
            SizedBox(
              width: 60,
              child: Text(tok.token,
                  style: GlimprType.mono(12.5, GlimprTokens.accent)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(desc,
                  style: GlimprType.sansStyle(12, 400, t.fg2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      );

  String _catLabel(AppLocalizations l, TokenCategory c) => switch (c) {
        TokenCategory.dateTime => l.tokCatDateTime,
        TokenCategory.content => l.tokCatContent,
        TokenCategory.counter => l.tokCatCounter,
        TokenCategory.random => l.tokCatRandom,
        TokenCategory.computer => l.tokCatComputer,
      };

  String _desc(AppLocalizations l, String token) => switch (token) {
        '%Y' => l.tokYear4,
        '%y' => l.tokYear2,
        '%m' => l.tokMonth,
        '%d' => l.tokDay,
        '%H' => l.tokHour24,
        '%I' => l.tokHour12,
        '%M' => l.tokMinute,
        '%S' => l.tokSecond,
        '%p' => l.tokAmPm,
        '%j' => l.tokDayOfYear,
        '%V' => l.tokWeek,
        '%a' => l.tokWeekdayShort,
        '%A' => l.tokWeekdayFull,
        '%b' => l.tokMonthShort,
        '%B' => l.tokMonthFull,
        '%s' => l.tokUnix,
        '%title' => l.tokTitle,
        '%app' => l.tokApp,
        '%i' => l.tokCounter,
        '%ra' => l.tokRandAlnum,
        '%rn' => l.tokRandNum,
        '%rx' => l.tokRandHex,
        '%guid' => l.tokGuid,
        '%host' => l.tokHost,
        '%user' => l.tokUser,
        _ => '',
      };
}
