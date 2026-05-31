import 'package:flutter/material.dart';

/// Draws [child] and lets the user drag a selection rectangle over it.
/// Reports the rectangle in the child's LOCAL logical coordinates on release.
class Marquee extends StatefulWidget {
  final Widget child;
  final void Function(Rect selection) onSelected;
  const Marquee({super.key, required this.child, required this.onSelected});

  @override
  State<Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<Marquee> {
  Offset? _start;
  Offset? _current;

  Rect? get _rect => (_start != null && _current != null)
      ? Rect.fromPoints(_start!, _current!)
      : null;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (d) => setState(() {
        _start = d.localPosition;
        _current = d.localPosition;
      }),
      onPanUpdate: (d) => setState(() => _current = d.localPosition),
      onPanEnd: (_) {
        final r = _rect;
        if (r != null && r.width >= 2 && r.height >= 2) widget.onSelected(r);
        setState(() {
          _start = null;
          _current = null;
        });
      },
      child: Stack(
        children: [
          widget.child,
          if (_rect != null)
            Positioned.fromRect(
              rect: _rect!,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.15),
                  border: Border.all(color: Colors.blue, width: 1),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
