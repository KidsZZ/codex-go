import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:codex_go/infrastructure/platform/attachments.dart';
import 'package:codex_go/l10n/strings.dart';

/// 编辑发生在加入上传队列之前；取消不会上传原图，完成也不会修改相册原件。
Future<LocalAttachment?> editAttachmentImage(
  BuildContext context,
  LocalAttachment source,
) => Navigator.of(context).push<LocalAttachment>(
  MaterialPageRoute(builder: (_) => ImageAttachmentEditor(source: source)),
);

class ImageAttachmentEditor extends StatefulWidget {
  const ImageAttachmentEditor({required this.source, super.key});
  final LocalAttachment source;

  @override
  State<ImageAttachmentEditor> createState() => _ImageAttachmentEditorState();
}

enum _Tool { crop, pen }

enum _Handle { topLeft, topRight, bottomLeft, bottomRight, move, create }

class _Stroke {
  _Stroke(this.color, this.width, this.points);
  final Color color;
  // 宽度与坐标都相对于整张图片，旋转设备、裁剪和导出不会错位。
  final double width;
  final List<Offset> points;
}

class _EditSnapshot {
  const _EditSnapshot(this.crop, this.strokes);
  final Rect crop;
  final List<_Stroke> strokes;
}

class _ImageAttachmentEditorState extends State<ImageAttachmentEditor> {
  static const _whole = Rect.fromLTWH(0, 0, 1, 1);
  static const _colors = [
    Colors.red,
    Colors.amber,
    Colors.blue,
    Colors.black,
    Colors.white,
  ];
  ui.Image? _image;
  bool _failed = false;
  bool _saving = false;
  bool _resized = false;
  bool _animated = false;
  _Tool _tool = _Tool.crop;
  Color _color = Colors.red;
  double _brush = 5;
  Rect _crop = _whole;
  Rect _display = Rect.zero;
  final List<_Stroke> _strokes = [];
  final List<_EditSnapshot> _history = [];
  _Stroke? _currentStroke;
  _Handle? _handle;
  Offset _start = Offset.zero;
  Rect _startCrop = _whole;

  bool get _changed => _crop != _whole || _strokes.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(widget.source.path);
      final codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (width, height) {
          // 限制解码峰值内存；需要原始分辨率时可明确选择「使用原图」。
          final scale = math.min(1.0, 4096 / math.max(width, height));
          _resized = scale < 1;
          return ui.TargetImageSize(
            width: math.max(1, (width * scale).round()),
            height: math.max(1, (height * scale).round()),
          );
        },
      );
      try {
        _animated = codec.frameCount > 1;
        final frame = await codec.getNextFrame();
        if (!mounted) {
          frame.image.dispose();
          return;
        }
        setState(() => _image = frame.image);
      } finally {
        codec.dispose();
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  void _remember() => _history.add(_EditSnapshot(_crop, List.of(_strokes)));

  void _undo() {
    if (_history.isEmpty) return;
    final previous = _history.removeLast();
    setState(() {
      _crop = previous.crop;
      _strokes
        ..clear()
        ..addAll(previous.strokes);
      _currentStroke = null;
      _handle = null;
    });
  }

  Offset _point(Offset local) => Offset(
    ((local.dx - _display.left) / _display.width).clamp(0.0, 1.0),
    ((local.dy - _display.top) / _display.height).clamp(0.0, 1.0),
  );

  void _begin(DragStartDetails event) {
    if (_saving || !_display.contains(event.localPosition)) return;
    _start = _point(event.localPosition);
    _startCrop = _crop;
    _remember();
    if (_tool == _Tool.pen) {
      _currentStroke = _Stroke(_color, _brush / _display.shortestSide, [
        _start,
      ]);
      setState(() => _strokes.add(_currentStroke!));
      return;
    }
    final corners = {
      _Handle.topLeft: _crop.topLeft,
      _Handle.topRight: _crop.topRight,
      _Handle.bottomLeft: _crop.bottomLeft,
      _Handle.bottomRight: _crop.bottomRight,
    };
    _handle = null;
    var distance = 30.0;
    for (final corner in corners.entries) {
      final delta = corner.value - _start;
      final pixels = Offset(
        delta.dx * _display.width,
        delta.dy * _display.height,
      ).distance;
      if (pixels < distance) {
        distance = pixels;
        _handle = corner.key;
      }
    }
    _handle ??= _crop.contains(_start) ? _Handle.move : _Handle.create;
  }

  void _move(DragUpdateDetails event) {
    if (_saving) return;
    final p = _point(event.localPosition);
    if (_tool == _Tool.pen) {
      if (_currentStroke != null) setState(() => _currentStroke!.points.add(p));
      return;
    }
    if (_handle == null) return;
    final r = _startCrop;
    final dx = p.dx - _start.dx, dy = p.dy - _start.dy;
    const minimum = .025;
    final rect = switch (_handle!) {
      _Handle.topLeft => Rect.fromLTRB(
        math.min(p.dx, r.right - minimum),
        math.min(p.dy, r.bottom - minimum),
        r.right,
        r.bottom,
      ),
      _Handle.topRight => Rect.fromLTRB(
        r.left,
        math.min(p.dy, r.bottom - minimum),
        math.max(p.dx, r.left + minimum),
        r.bottom,
      ),
      _Handle.bottomLeft => Rect.fromLTRB(
        math.min(p.dx, r.right - minimum),
        r.top,
        r.right,
        math.max(p.dy, r.top + minimum),
      ),
      _Handle.bottomRight => Rect.fromLTRB(
        r.left,
        r.top,
        math.max(p.dx, r.left + minimum),
        math.max(p.dy, r.top + minimum),
      ),
      _Handle.move => Rect.fromLTWH(
        (r.left + dx).clamp(0.0, 1 - r.width),
        (r.top + dy).clamp(0.0, 1 - r.height),
        r.width,
        r.height,
      ),
      _Handle.create => Rect.fromPoints(_start, p),
    };
    if (rect.width >= minimum && rect.height >= minimum) {
      setState(() => _crop = rect);
    }
  }

  void _end() {
    _currentStroke = null;
    _handle = null;
  }

  Future<void> _save() async {
    if (_saving || _image == null) return;
    if (!_changed) {
      Navigator.pop(context, widget.source);
      return;
    }
    setState(() => _saving = true);
    final image = _image!.clone();
    File? output;
    try {
      final crop = Rect.fromLTRB(
        (_crop.left * image.width).floorToDouble(),
        (_crop.top * image.height).floorToDouble(),
        (_crop.right * image.width).ceilToDouble(),
        (_crop.bottom * image.height).ceilToDouble(),
      );
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.translate(-crop.left, -crop.top);
      canvas.drawImage(image, Offset.zero, Paint());
      _paintStrokes(
        canvas,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        _strokes,
      );
      final picture = recorder.endRecording();
      final ui.Image result;
      try {
        result = await picture.toImage(crop.width.toInt(), crop.height.toInt());
      } finally {
        picture.dispose();
      }
      final ByteData? bytes;
      try {
        bytes = await result.toByteData(format: ui.ImageByteFormat.png);
      } finally {
        result.dispose();
      }
      if (bytes == null) throw StateError('Image encoding failed');
      // picked 文件本身已是唯一的缓存副本，编辑结果使用独立路径。
      output = File('${widget.source.path}.edited.png');
      await output.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
      final stem = widget.source.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
      final attachment = LocalAttachment(
        name: '$stem-edited.png',
        path: output.path,
        size: bytes.lengthInBytes,
        isImage: true,
        mimeType: 'image/png',
      );
      Attachments.validate([attachment]);
      if (!mounted) {
        await output.delete();
        return;
      }
      // 先解除保存保护，再退出路由；完成前返回键不应丢弃仍在生成的图片。
      setState(() => _saving = false);
      Navigator.pop(context, attachment);
    } catch (_) {
      if (output != null && await output.exists()) await output.delete();
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.imageEditSaveFailed)),
        );
      }
    } finally {
      image.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final image = _image;
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            l.imageEditTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          leading: IconButton(
            tooltip: l.cancel,
            icon: const Icon(Icons.close),
            onPressed: _saving ? null : () => Navigator.maybePop(context),
          ),
          actions: [
            TextButton(
              onPressed: _saving
                  ? null
                  : () => Navigator.pop(context, widget.source),
              child: Text(l.imageEditOriginal),
            ),
            TextButton(
              onPressed: image == null || _saving ? null : _save,
              child: Text(l.imageEditDone),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              if (_saving) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: _failed
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(l.imageEditLoadFailed),
                        ),
                      )
                    : image == null
                    ? const Center(child: CircularProgressIndicator())
                    : Padding(
                        padding: const EdgeInsets.all(20),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final size = Size(
                              constraints.maxWidth,
                              constraints.maxHeight,
                            );
                            final fitted = applyBoxFit(
                              BoxFit.contain,
                              Size(
                                image.width.toDouble(),
                                image.height.toDouble(),
                              ),
                              size,
                            ).destination;
                            _display = Alignment.center.inscribe(
                              fitted,
                              Offset.zero & size,
                            );
                            return GestureDetector(
                              key: const Key('image-edit-canvas'),
                              behavior: HitTestBehavior.opaque,
                              onTapUp: (event) {
                                if (_saving ||
                                    _tool != _Tool.pen ||
                                    !_display.contains(event.localPosition)) {
                                  return;
                                }
                                _remember();
                                setState(
                                  () => _strokes.add(
                                    _Stroke(
                                      _color,
                                      _brush / _display.shortestSide,
                                      [_point(event.localPosition)],
                                    ),
                                  ),
                                );
                              },
                              onPanStart: _begin,
                              onPanUpdate: _move,
                              onPanEnd: (_) => _end(),
                              onPanCancel: _end,
                              child: CustomPaint(
                                size: size,
                                painter: _EditorPainter(
                                  image,
                                  _display,
                                  _crop,
                                  _strokes,
                                  _tool == _Tool.crop,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
              ),
              if (image != null) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    _tool == _Tool.crop
                        ? l.imageEditCropHint
                        : l.imageEditPenHint,
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
                if (_resized || _animated)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: Text(
                      _animated
                          ? l.imageEditAnimatedHint
                          : l.imageEditResizeHint,
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (_tool == _Tool.pen) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < _colors.length; i++)
                        IconButton(
                          tooltip: [
                            l.imageEditRed,
                            l.imageEditYellow,
                            l.imageEditBlue,
                            l.imageEditBlack,
                            l.imageEditWhite,
                          ][i],
                          onPressed: _saving
                              ? null
                              : () => setState(() => _color = _colors[i]),
                          icon: Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: _colors[i],
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _color == _colors[i]
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.grey,
                                width: _color == _colors[i] ? 3 : 1,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        Text(l.imageEditBrushSize),
                        Expanded(
                          child: Slider(
                            value: _brush,
                            min: 2,
                            max: 16,
                            divisions: 14,
                            label: _brush.round().toString(),
                            onChanged: _saving
                                ? null
                                : (v) => setState(() => _brush = v),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        ChoiceChip(
                          label: Text(l.imageEditCrop),
                          avatar: const Icon(Icons.crop, size: 18),
                          selected: _tool == _Tool.crop,
                          onSelected: _saving
                              ? null
                              : (_) => setState(() => _tool = _Tool.crop),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: Text(l.imageEditPen),
                          avatar: const Icon(Icons.edit, size: 18),
                          selected: _tool == _Tool.pen,
                          onSelected: _saving
                              ? null
                              : (_) => setState(() => _tool = _Tool.pen),
                        ),
                        IconButton(
                          tooltip: l.imageEditUndo,
                          onPressed: _saving || _history.isEmpty ? null : _undo,
                          icon: const Icon(Icons.undo),
                        ),
                        IconButton(
                          tooltip: l.imageEditReset,
                          onPressed: _saving || !_changed
                              ? null
                              : () {
                                  _remember();
                                  setState(() {
                                    _crop = _whole;
                                    _strokes.clear();
                                  });
                                },
                          icon: const Icon(Icons.restart_alt),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

void _paintStrokes(Canvas canvas, Rect area, List<_Stroke> strokes) {
  canvas.save();
  canvas.clipRect(area);
  for (final stroke in strokes) {
    final paint = Paint()
      ..color = stroke.color
      ..strokeWidth = stroke.width * area.shortestSide
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Offset point(Offset p) =>
        Offset(area.left + p.dx * area.width, area.top + p.dy * area.height);
    if (stroke.points.length == 1) {
      canvas.drawCircle(
        point(stroke.points.first),
        paint.strokeWidth / 2,
        Paint()..color = stroke.color,
      );
    } else {
      final path = Path()
        ..moveTo(point(stroke.points.first).dx, point(stroke.points.first).dy);
      for (final p in stroke.points.skip(1)) {
        final at = point(p);
        path.lineTo(at.dx, at.dy);
      }
      canvas.drawPath(path, paint);
    }
  }
  canvas.restore();
}

class _EditorPainter extends CustomPainter {
  const _EditorPainter(
    this.image,
    this.area,
    this.crop,
    this.strokes,
    this.handles,
  );
  final ui.Image image;
  final Rect area, crop;
  final List<_Stroke> strokes;
  final bool handles;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      area,
      Paint()..filterQuality = FilterQuality.medium,
    );
    _paintStrokes(canvas, area, strokes);
    final selected = Rect.fromLTRB(
      area.left + crop.left * area.width,
      area.top + crop.top * area.height,
      area.left + crop.right * area.width,
      area.top + crop.bottom * area.height,
    );
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(area)
      ..addRect(selected);
    canvas.drawPath(shade, Paint()..color = Colors.black.withValues(alpha: .6));
    canvas.drawRect(
      selected,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    if (handles) {
      final grid = Paint()
        ..color = Colors.white.withValues(alpha: .4)
        ..strokeWidth = 1;
      for (var i = 1; i < 3; i++) {
        final x = selected.left + selected.width * i / 3,
            y = selected.top + selected.height * i / 3;
        canvas.drawLine(
          Offset(x, selected.top),
          Offset(x, selected.bottom),
          grid,
        );
        canvas.drawLine(
          Offset(selected.left, y),
          Offset(selected.right, y),
          grid,
        );
      }
      for (final p in [
        selected.topLeft,
        selected.topRight,
        selected.bottomLeft,
        selected.bottomRight,
      ]) {
        canvas.drawCircle(p, 7, Paint()..color = Colors.white);
        canvas.drawCircle(
          p,
          7,
          Paint()
            ..color = Colors.black54
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _EditorPainter oldDelegate) => true;
}
