import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';

import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/input_model.dart';

import './gestures.dart';

const _touchOnlyGestureDevices = <PointerDeviceKind>{PointerDeviceKind.touch};

class RawKeyFocusScope extends StatelessWidget {
  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChange;
  final InputModel inputModel;
  final Widget child;

  RawKeyFocusScope({
    this.focusNode,
    this.onFocusChange,
    required this.inputModel,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // https://github.com/flutter/flutter/issues/154053
    final useRawKeyEvents = isLinux && !isWeb;
    // FIXME: On Windows, `AltGr` will generate `Alt` and `Control` key events,
    // while `Alt` and `Control` are separated key events for en-US input method.
    return FocusScope(
        autofocus: true,
        child: Focus(
            autofocus: true,
            canRequestFocus: true,
            focusNode: focusNode,
            onFocusChange: onFocusChange,
            onKey: useRawKeyEvents
                ? (FocusNode data, RawKeyEvent event) =>
                    inputModel.handleRawKeyEvent(event)
                : null,
            onKeyEvent: useRawKeyEvents
                ? null
                : (FocusNode node, KeyEvent event) =>
                    inputModel.handleKeyEvent(event),
            child: child));
  }
}

// For virtual mouse when using the mouse mode on mobile.
// Special hold-drag mode: one finger holds a button (left/right button), another finger pans.
// This flag is to override the scale gesture to a pan gesture.
bool isSpecialHoldDragActive = false;
// Cache the last focal point to calculate deltas in special hold-drag mode.
Offset _lastSpecialHoldDragFocalPoint = Offset.zero;

class _NaturalScrollAccumulator {
  static const double _pixelsPerStep = 12.0;

  double _accX = 0;
  double _accY = 0;

  Future<void> add(
    Offset delta,
    InputModel inputModel, {
    required Future<void> Function() updateCursor,
  }) async {
    if (delta.dx.abs() > delta.dy.abs()) {
      _accX += delta.dx;
      _accY = 0;
    } else {
      _accY += delta.dy;
      _accX = 0;
    }

    await updateCursor();
    final stepsY = (_accY / _pixelsPerStep).round();
    final stepsX = (_accX / _pixelsPerStep).round();
    _accY -= stepsY * _pixelsPerStep;
    _accX -= stepsX * _pixelsPerStep;

    if ((stepsX != 0 || stepsY != 0) && !inputModel.isViewOnly) {
      await inputModel.scroll(stepsY, x: stepsX);
    }
  }

  void reset() {
    _accX = 0;
    _accY = 0;
  }
}

enum _PointerContactMode { pending, scrolling, dragging, longPressed }

class _PointerContact {
  _PointerContact(this.startPosition, {this.onLongPress}) {
    _dragReadyTimer = Timer(const Duration(milliseconds: 300), () {
      if (mode == _PointerContactMode.pending &&
          maxMovement <= _dragPreparationSlop) {
        dragPrepared = true;
      }
    });
    if (onLongPress != null) {
      _longPressTimer = Timer(const Duration(milliseconds: 280), () {
        if (mode == _PointerContactMode.pending &&
            maxMovement <= _dragPreparationSlop) {
          mode = _PointerContactMode.longPressed;
          onLongPress!();
        }
      });
    }
  }

  static const double _dragPreparationSlop = 8.0;
  final Offset startPosition;
  final _NaturalScrollAccumulator scroll = _NaturalScrollAccumulator();
  final VoidCallback? onLongPress;
  late final Timer _dragReadyTimer;
  Timer? _longPressTimer;
  _PointerContactMode mode = _PointerContactMode.pending;
  double maxMovement = 0;
  bool dragPrepared = false;
  bool dragButtonDownSent = false;
  bool rightButtonDownSent = false;
  bool _usesTouchPan = false;
  bool _touchPanStarted = false;
  Offset _lastPanPosition = Offset.zero;
  InputModel? _panInputModel;
  Future<void> _updateQueue = Future<void>.value();
  bool _ending = false;

  // Keep receiving updates after long press so the held right button can drag.
  bool get isActive => true;

  void update({
    required Offset position,
    required Offset delta,
    required Offset panPosition,
    required InputModel inputModel,
    required Future<void> Function() updateCursor,
    required void Function(Offset position) startPan,
    required void Function(Offset delta) updatePan,
    required Future<void> Function() movePointer,
    required Future<void> Function() startDrag,
    required Future<void> Function() updateDrag,
  }) {
    if (_ending) return;
    maxMovement = max(maxMovement, (position - startPosition).distance);
    var startedDrag = false;
    if (mode == _PointerContactMode.pending &&
        maxMovement > _dragPreparationSlop) {
      if (dragPrepared) {
        mode = _PointerContactMode.dragging;
        startedDrag = true;
        _longPressTimer?.cancel();
      } else {
        mode = _PointerContactMode.scrolling;
        _dragReadyTimer.cancel();
        _longPressTimer?.cancel();
        _usesTouchPan = inputModel.peerPlatform == kPeerPlatformAndroid;
        if (_usesTouchPan) {
          _panInputModel = inputModel;
        }
      }
    }

    if (mode == _PointerContactMode.scrolling && _usesTouchPan) {
      _lastPanPosition = panPosition;
    }
    final modeAtEvent = mode;
    _updateQueue = _updateQueue.then((_) async {
      if (startedDrag) {
        scroll.reset();
        await startDrag();
        dragButtonDownSent = true;
      }
      switch (modeAtEvent) {
        case _PointerContactMode.pending:
        case _PointerContactMode.scrolling:
          if (_usesTouchPan) {
            if (!_touchPanStarted) {
              if (!inputModel.isViewOnly) {
                startPan(panPosition);
              }
              _touchPanStarted = true;
            }
            if (!inputModel.isViewOnly) {
              updatePan(delta);
            }
          } else {
            // Keep the pointer under the finger/stylus while also preserving
            // touchpad-style page scrolling on desktop hosts.  The previous
            // raw-pointer-only path moved the cursor but could never scroll
            // webpages or documents.  Two-finger scrolling is handled by its
            // separate path and is intentionally unchanged.
            await movePointer();
            await scroll.add(delta, inputModel, updateCursor: updateCursor);
          }
          return;
        case _PointerContactMode.longPressed:
          await movePointer();
          return;
        case _PointerContactMode.dragging:
          await updateDrag();
          return;
      }
    });
  }

  Future<void> finish({
    required Future<void> Function() releaseDrag,
    Offset? panEndPosition,
    Future<void> Function()? releaseRightDrag,
  }) async {
    if (_ending) return;
    _ending = true;
    _dragReadyTimer.cancel();
    _longPressTimer?.cancel();
    if (panEndPosition != null && _usesTouchPan) {
      _lastPanPosition = panEndPosition;
    }
    try {
      await _updateQueue;
    } finally {
      if (dragButtonDownSent) {
        await releaseDrag();
        dragButtonDownSent = false;
      }
      if (rightButtonDownSent && releaseRightDrag != null) {
        await releaseRightDrag();
        rightButtonDownSent = false;
      }
      if (_touchPanStarted && !(_panInputModel?.isViewOnly ?? true)) {
        _panInputModel?.handlePointerEvent(
            'touch', kMouseEventTypePanEnd, _lastPanPosition);
      }
      if (_touchPanStarted) {
        _touchPanStarted = false;
      }
      scroll.reset();
    }
  }

  void dispose() {
    _ending = true;
    _dragReadyTimer.cancel();
    _longPressTimer?.cancel();
    scroll.reset();
  }
}

class RawTouchGestureDetectorRegion extends StatefulWidget {
  final Widget child;
  final FFI ffi;
  final bool isCamera;
  late final InputModel inputModel = ffi.inputModel;
  late final FfiModel ffiModel = ffi.ffiModel;

  RawTouchGestureDetectorRegion({
    required this.child,
    required this.ffi,
    this.isCamera = false,
  });

  @override
  State<RawTouchGestureDetectorRegion> createState() =>
      _RawTouchGestureDetectorRegionState();
}

/// touchMode only:
///   LongPress -> right click
///   Android mobile OneFingerPan -> scroll or hold-to-drag
///   Other OneFingerPan -> start/end -> left down start/end
///   onDoubleTapDown -> move to
///   onLongPressDown => move to
///
/// mouseMode only:
///   DoubleFiner -> right click
///   HoldDrag -> left drag
class _RawTouchGestureDetectorRegionState
    extends State<RawTouchGestureDetectorRegion> {
  Offset _cacheLongPressPosition = Offset(0, 0);
  // Timestamp of the last long press event.
  int _cacheLongPressPositionTs = 0;
  double _mouseScrollIntegral = 0; // mouse scroll speed controller
  double _scale = 1;

  // Android two-finger scrolling. Accumulate the focal-point movement and
  // emit one merged wheel event at a low interval.
  static const double _twoFingerScrollThreshold = 10.0;
  static const int _twoFingerScrollIntervalUs = 18000;
  Offset _lastTwoFingerFocalPoint = Offset.zero;
  double _twoFingerScrollIntegralX = 0;
  double _twoFingerScrollIntegralY = 0;
  int _lastTwoFingerScrollTsUs = 0;
  final Map<int, Offset> _activeTouchPositions = {};
  final Map<int, Offset> _activeTouchRemotePositions = {};
  // In native touch mode, two contacts become a touchpad gesture instead of
  // raw touchscreen input. A single contact keeps native touchscreen behavior.
  bool _nativeTouchTwoFingerMode = false;
  Map<int, Offset>? _twoFingerTapStartPositions;
  int _twoFingerTapStartTsUs = 0;
  double _twoFingerTapMaxMovement = 0;
  bool _isTwoFingerTapCandidate = false;
  bool _twoFingerTapScrollSent = false;
  final Map<int, _PointerContact> _touchContacts = {};
  bool _androidSingleFingerScrollHandled = false;
  // Workaround tap down event when two fingers are used to scale(mobile)
  TapDownDetails? _lastTapDownDetails;

  PointerDeviceKind? lastDeviceKind;

  // For touch mode, onDoubleTap
  // `onDoubleTap()` does not provide the position of the tap event.
  Offset _lastPosOfDoubleTapDown = Offset.zero;
  bool _touchModePanStarted = false;
  Offset _doubleFinerTapPosition = Offset.zero;

  // For mouse mode, we need to block the events when the cursor is in a blocked area.
  // So we need to cache the last tap down position.
  Offset? _lastTapDownPositionForMouseMode;
  // Cache global position for onTap (which lacks position info).
  Offset? _lastTapDownGlobalPosition;
  // Cache the canvas pointer-down used by gesture callbacks to distinguish a
  // tap on KeyHelpTools from a tap on the remote canvas.
  PointerDownEvent? _lastPointerDownEvent;

  FFI get ffi => widget.ffi;
  FfiModel get ffiModel => widget.ffiModel;
  InputModel get inputModel => widget.inputModel;
  bool get handleTouch => (isDesktop || isWebDesktop) || ffiModel.touchMode;
  SessionID get sessionId => ffi.sessionId;
  bool get canvasLocked => isMobile && ffi.canvasModel.locked;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: RawGestureDetector(
        child: widget.child,
        gestures: makeGestures(context),
      ),
    );
  }

  @override
  void didUpdateWidget(RawTouchGestureDetectorRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ffi.sessionId != widget.ffi.sessionId) {
      _cancelTouchContacts(inputModel: oldWidget.ffi.inputModel);
      _resetNativeTouchState();
      _resetTwoFingerTapState();
      _resetTwoFingerScrollState();
    }
  }

  bool get _isAndroidMobileClient =>
      isAndroid && isMobile && !isDesktop && !isWebDesktop;

  bool get _isAndroidTouchMode =>
      _isAndroidMobileClient && ffiModel.touchMode;

  bool get _useNativeTouch =>
      _isAndroidTouchMode && inputModel.peerPlatform != kPeerPlatformAndroid;

  bool get _touchDownOnKeyHelpTools {
    if (!_isAndroidTouchMode) return false;
    final event = _lastPointerDownEvent;
    if (event == null || event.kind != PointerDeviceKind.touch) {
      return false;
    }
    return ffi.cursorModel.shouldBlock(
      event.localPosition.dx,
      event.localPosition.dy,
    );
  }

  Map<String, dynamic> _buildNativeTouchFrame(PointerEvent event) {
    if (_activeTouchPositions.containsKey(event.pointer)) {
      _activeTouchPositions[event.pointer] = event.localPosition;
    }
    final pos = inputModel.remoteCanvasPositionForPointer(event);
    _activeTouchRemotePositions[event.pointer] = pos;
    final rect = ffiModel.rect;
    final width = max(1, rect?.width.round() ?? 1);
    final height = max(1, rect?.height.round() ?? 1);
    final points = <Map<String, dynamic>>[];
    int action;
    if (event is PointerDownEvent) {
      action = 0;
    } else if (event is PointerUpEvent) {
      action = 2;
    } else if (event is PointerCancelEvent) {
      action = 3;
    } else {
      action = 1;
    }
    for (final entry in _activeTouchPositions.entries) {
      final remotePosition = _activeTouchRemotePositions[entry.key];
      if (remotePosition == null) {
        continue;
      }
      points.add({
        'id': entry.key,
        'x': remotePosition.dx.round().clamp(0, width),
        'y': remotePosition.dy.round().clamp(0, height),
        'action': entry.key == event.pointer ? action : 1,
        'pressure': event.kind == PointerDeviceKind.stylus ? 512 : 0,
      });
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _activeTouchPositions.remove(event.pointer);
      _activeTouchRemotePositions.remove(event.pointer);
    }
    return {
      'width': width,
      'height': height,
      'points': points,
    };
  }

  void _sendNativeTouchFrame(PointerEvent event) {
    if (!_useNativeTouch || inputModel.isViewOnly) {
      return;
    }
    final frame = _buildNativeTouchFrame(event);
    final points = frame['points'] as List?;
    if (points == null || points.isEmpty) {
      return;
    }
    final evt = PointerEventToRust(
      kPointerEventKindTouch,
      'native',
      frame,
    ).toJson();
    bind.sessionSendPointer(
      sessionId: sessionId,
      msg: json.encode(inputModel.modify(evt)),
    );
  }

  void _cancelNativeTouchContacts(PointerEvent event) {
    // The second contact switches to touchpad mode before any raw pointer
    // up frame can be sent. Release all pending native contacts to avoid
    // stuck remote touch pointers when the touchpad gesture ends.
    if (_activeTouchPositions.isNotEmpty) {
      final rect = ffiModel.rect;
      final width = max(1, rect?.width.round() ?? 1);
      final height = max(1, rect?.height.round() ?? 1);
      final points = <Map<String, dynamic>>[];
      for (final entry in _activeTouchPositions.entries) {
        final remotePosition = _activeTouchRemotePositions[entry.key];
        if (remotePosition == null) {
          continue;
        }
        points.add({
          'id': entry.key,
          'x': remotePosition.dx.round().clamp(0, width),
          'y': remotePosition.dy.round().clamp(0, height),
          'action': 2,
          'pressure': 0,
        });
      }
      if (points.isNotEmpty) {
        final evt = PointerEventToRust(
          kPointerEventKindTouch,
          'native',
          {'width': width, 'height': height, 'points': points},
        ).toJson();
        bind.sessionSendPointer(
          sessionId: sessionId,
          msg: json.encode(inputModel.modify(evt)),
        );
      }
    }
    final savedPositions = Map.of(_activeTouchPositions);
    _resetNativeTouchState();
    // Keep local tracking for the touchpad gesture; only remote raw contacts
    // were released above.
    _activeTouchPositions.addAll(savedPositions);
    _nativeTouchTwoFingerMode = true;
  }

  void _resetNativeTouchState() {
    _activeTouchPositions.clear();
    _activeTouchRemotePositions.clear();
    _nativeTouchTwoFingerMode = false;
  }

  void _onPointerDown(PointerDownEvent event) {
    _lastPointerDownEvent = event;
    if (event.kind == PointerDeviceKind.touch) {
      _activeTouchPositions[event.pointer] = event.localPosition;
      if (_useNativeTouch && _activeTouchPositions.length < 2) {
        _sendNativeTouchFrame(event);
        return;
      }
      if (_useNativeTouch && _activeTouchPositions.length >= 2) {
        _nativeTouchTwoFingerMode = true;
        _cancelNativeTouchContacts(event);
      }
      if (_isAndroidTouchMode && _activeTouchPositions.length == 1) {
        _androidSingleFingerScrollHandled = false;
        if (!ffi.cursorModel.shouldBlock(
                event.localPosition.dx, event.localPosition.dy) &&
            ffi.cursorModel.isInRemoteRect(event.localPosition)) {
          final pointerInputModel = inputModel;
          final cursorModel = ffi.cursorModel;
          pointerInputModel.handleMouse(
            InputModel.getMouseEventMove(),
            event.localPosition,
          );
          _PointerContact? contact;
          contact = _PointerContact(
            event.localPosition,
            onLongPress: () {
              _androidSingleFingerScrollHandled = true;
              if (!pointerInputModel.isViewOnly &&
                  cursorModel.isInRemoteRect(event.localPosition)) {
                unawaited((() async {
                  contact?.rightButtonDownSent = true;
                  await pointerInputModel.sendMouse('down', MouseButtons.right);
                })());
              }
            },
          );
          _touchContacts[event.pointer] = contact;
        }
      } else if (_activeTouchPositions.length > 1) {
        _cancelTouchContacts(suppressTap: true);
      }
      if (_isAndroidTouchMode && _activeTouchPositions.length == 2) {
        _twoFingerTapStartPositions = Map.of(_activeTouchPositions);
        _twoFingerTapStartTsUs = DateTime.now().microsecondsSinceEpoch;
        _twoFingerTapMaxMovement = 0;
        _twoFingerTapScrollSent = false;
        _isTwoFingerTapCandidate = true;
        _lastTwoFingerFocalPoint = _activeTouchFocalPoint;
        _lastTwoFingerScrollTsUs = 0;
      } else if (_activeTouchPositions.length > 2) {
        _isTwoFingerTapCandidate = false;
      }
    }
  }

  Offset get _activeTouchFocalPoint {
    if (_activeTouchPositions.isEmpty) return Offset.zero;
    var sum = Offset.zero;
    for (final position in _activeTouchPositions.values) {
      sum += position;
    }
    return sum / _activeTouchPositions.length.toDouble();
  }

  Future<void> _handleAndroidTwoFingerMove() async {
    if (!_isAndroidTouchMode || _activeTouchPositions.length != 2) return;

    final delta = _activeTouchFocalPoint - _lastTwoFingerFocalPoint;
    _lastTwoFingerFocalPoint = _activeTouchFocalPoint;
    if (delta == Offset.zero || inputModel.isViewOnly) return;

    // Keep the existing, verified two-finger wheel speed and natural direction.
    // The difference is that the raw pointer frame is used directly, like
    // Moonlight's MotionEvent path, instead of waiting for ScaleRecognizer.
    if (delta.dx.abs() > delta.dy.abs()) {
      _twoFingerScrollIntegralX += delta.dx;
      _twoFingerScrollIntegralY = 0;
    } else {
      _twoFingerScrollIntegralY += delta.dy;
      _twoFingerScrollIntegralX = 0;
    }

    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final elapsedUs = _lastTwoFingerScrollTsUs == 0
        ? 1000000
        : nowUs - _lastTwoFingerScrollTsUs;
    if (elapsedUs < _twoFingerScrollIntervalUs) return;

    if (_twoFingerScrollIntegralY.abs() >= _twoFingerScrollThreshold) {
      final steps = min(
          4,
          (_twoFingerScrollIntegralY.abs() / _twoFingerScrollThreshold)
              .floor());
      if (steps > 0) {
        _twoFingerTapScrollSent = true;
        await inputModel.scroll(_twoFingerScrollIntegralY.sign.toInt() * steps);
        _twoFingerScrollIntegralY -=
            _twoFingerScrollIntegralY.sign * steps * _twoFingerScrollThreshold;
        _lastTwoFingerScrollTsUs = nowUs;
      }
      return;
    }

    if (_twoFingerScrollIntegralX.abs() >= _twoFingerScrollThreshold) {
      final steps = min(
          4,
          (_twoFingerScrollIntegralX.abs() / _twoFingerScrollThreshold)
              .floor());
      if (steps > 0) {
        _twoFingerTapScrollSent = true;
        await inputModel.scroll(0,
            x: _twoFingerScrollIntegralX.sign.toInt() * steps);
        _twoFingerScrollIntegralX -=
            _twoFingerScrollIntegralX.sign * steps * _twoFingerScrollThreshold;
        _lastTwoFingerScrollTsUs = nowUs;
      }
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.kind == PointerDeviceKind.touch &&
        _activeTouchPositions.containsKey(event.pointer)) {
      _activeTouchPositions[event.pointer] = event.localPosition;
      if (_useNativeTouch && !_nativeTouchTwoFingerMode) {
        _sendNativeTouchFrame(event);
        return;
      }
      if (_isAndroidTouchMode && _activeTouchPositions.length == 2) {
        unawaited(_handleAndroidTwoFingerMove());
      }
      final contact = _touchContacts[event.pointer];
      if (_isAndroidTouchMode &&
          contact != null &&
          _activeTouchPositions.length == 1) {
        final pointerInputModel = inputModel;
        contact.update(
          position: event.localPosition,
          delta: event.delta,
          panPosition: event.localPosition,
          inputModel: pointerInputModel,
          updateCursor: () async {
            pointerInputModel.handleMouse(
              InputModel.getMouseEventMove(),
              event.localPosition,
            );
          },
          startPan: (position) => pointerInputModel.handlePointerEvent(
              'touch', kMouseEventTypePanStart, position),
          updatePan: (delta) => pointerInputModel.handlePointerEvent(
            'touch',
            kMouseEventTypePanUpdate,
            Offset(delta.dx.roundToDouble(), delta.dy.roundToDouble()),
          ),
          movePointer: () async {
            if (pointerInputModel.relativeMouseMode.value) {
              await pointerInputModel.sendMobileRelativeMouseMove(
                  event.delta.dx, event.delta.dy);
            } else {
              pointerInputModel.handleMouse(
                InputModel.getMouseEventMove(),
                event.localPosition,
              );
            }
          },
          startDrag: () async {
            await pointerInputModel.sendMouse('down', MouseButtons.left);
          },
          updateDrag: () async {
            final mouseEvent = InputModel.getMouseEventMove();
            mouseEvent['buttons'] = kPrimaryButton;
            pointerInputModel.handleMouse(mouseEvent, event.localPosition);
          },
        );
        if (contact.mode != _PointerContactMode.pending) {
          _androidSingleFingerScrollHandled = true;
        }
      }
      final startPositions = _twoFingerTapStartPositions;
      if (_isTwoFingerTapCandidate && startPositions != null) {
        final startPosition = startPositions[event.pointer];
        if (startPosition != null) {
          _twoFingerTapMaxMovement = max(
              _twoFingerTapMaxMovement,
              (event.localPosition - startPosition).distance);
        }
      }
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    final contact = _touchContacts.remove(event.pointer);
    if (contact != null) {
      if (contact.mode != _PointerContactMode.pending) {
        _androidSingleFingerScrollHandled = true;
      }
      unawaited(contact
          .finish(
              releaseDrag: () =>
                  inputModel.sendMouse('up', MouseButtons.left),
              panEndPosition: event.localPosition,
              releaseRightDrag: () =>
                  inputModel.sendMouse('up', MouseButtons.right))
          .whenComplete(contact.dispose));
    }
    if (event.kind != PointerDeviceKind.touch ||
        !_activeTouchPositions.containsKey(event.pointer)) {
      return;
    }
    _activeTouchPositions[event.pointer] = event.localPosition;
    if (_useNativeTouch && !_nativeTouchTwoFingerMode) {
      _sendNativeTouchFrame(event);
      return;
    }
    final startPositions = _twoFingerTapStartPositions;
    if (_isTwoFingerTapCandidate && startPositions != null) {
      final startPosition = startPositions[event.pointer];
      if (startPosition != null) {
        _twoFingerTapMaxMovement = max(
            _twoFingerTapMaxMovement,
            (event.localPosition - startPosition).distance);
      }
    }
    _activeTouchPositions.remove(event.pointer);

    if (_useNativeTouch && _nativeTouchTwoFingerMode) {
      _resetNativeTouchState();
      return;
    }

    if (_activeTouchPositions.isNotEmpty) return;

    final durationUs =
        DateTime.now().microsecondsSinceEpoch - _twoFingerTapStartTsUs;
    final shouldTapRight = _isAndroidTouchMode &&
        _isTwoFingerTapCandidate &&
        !_twoFingerTapScrollSent &&
        durationUs <= 250000 &&
        _twoFingerTapMaxMovement <= 20;
    _resetTwoFingerTapState();
    if (shouldTapRight) {
      unawaited(inputModel.tap(MouseButtons.right));
      return;
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    final contact = _touchContacts.remove(event.pointer);
    if (contact != null) {
      unawaited(contact
          .finish(
              releaseDrag: () =>
                  inputModel.sendMouse('up', MouseButtons.left),
              panEndPosition: event.localPosition,
              releaseRightDrag: () =>
                  inputModel.sendMouse('up', MouseButtons.right))
          .whenComplete(contact.dispose));
      _androidSingleFingerScrollHandled = true;
    }
    _activeTouchPositions[event.pointer] = event.localPosition;
    if (_useNativeTouch && !_nativeTouchTwoFingerMode) {
      _sendNativeTouchFrame(event);
      return;
    }
    _activeTouchPositions.remove(event.pointer);
    if (_useNativeTouch && _nativeTouchTwoFingerMode) {
      _resetNativeTouchState();
      return;
    }

    if (_activeTouchPositions.isEmpty) {
      _resetTwoFingerTapState();
    } else {
      _isTwoFingerTapCandidate = false;
    }
  }

  void _cancelTouchContacts({
    InputModel? inputModel,
    bool suppressTap = false,
  }) {
    final pointerInputModel = inputModel ?? this.inputModel;
    for (final contact in _touchContacts.values) {
      unawaited(contact
          .finish(
                  releaseDrag: () =>
                      pointerInputModel.sendMouse('up', MouseButtons.left),
                  releaseRightDrag: () =>
                      pointerInputModel.sendMouse('up', MouseButtons.right))
          .whenComplete(contact.dispose));
    }
    _touchContacts.clear();
    _androidSingleFingerScrollHandled = suppressTap;
  }

  void _resetTwoFingerTapState() {
    _twoFingerTapStartPositions = null;
    _twoFingerTapStartTsUs = 0;
    _twoFingerTapMaxMovement = 0;
    _isTwoFingerTapCandidate = false;
    _twoFingerTapScrollSent = false;
  }

  @override
  void dispose() {
    _cancelTouchContacts();
    super.dispose();
  }

  bool isNotTouchBasedDevice() {
    return !kTouchBasedDeviceKinds.contains(lastDeviceKind);
  }

  // Mobile, mouse mode.
  // Check if should block the mouse tap event (`_lastTapDownPositionForMouseMode`).
  bool shouldBlockMouseModeEvent() {
    return _lastTapDownPositionForMouseMode != null &&
        ffi.cursorModel.shouldBlock(_lastTapDownPositionForMouseMode!.dx,
            _lastTapDownPositionForMouseMode!.dy);
  }

  onTapDown(TapDownDetails d) async {
    if (_touchDownOnKeyHelpTools) {
      _androidSingleFingerScrollHandled = false;
      return;
    }
    lastDeviceKind = d.kind;
    _lastTapDownGlobalPosition = d.globalPosition;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (handleTouch) {
      _lastPosOfDoubleTapDown = d.localPosition;
      // Desktop or mobile "Touch mode"
      _lastTapDownDetails = d;
    } else {
      _lastTapDownPositionForMouseMode = d.localPosition;
    }
  }

  onTapUp(TapUpDetails d) async {
    if (_isAndroidTouchMode && _androidSingleFingerScrollHandled) {
      _androidSingleFingerScrollHandled = false;
      _lastTapDownDetails = null;
      return;
    }
    final TapDownDetails? lastTapDownDetails = _lastTapDownDetails;
    _lastTapDownDetails = null;
    if (isNotTouchBasedDevice()) {
      return;
    }
    // Filter duplicate touch tap events on iOS (Magic Mouse issue).
    if (inputModel.shouldIgnoreTouchTap(d.globalPosition)) {
      return;
    }
    if (handleTouch) {
      final isMoved =
          await ffi.cursorModel.move(d.localPosition.dx, d.localPosition.dy);
      if (isMoved) {
        // If pan already handled 'down', don't send it again.
        if (lastTapDownDetails != null && !_touchModePanStarted) {
          await inputModel.tapDown(MouseButtons.left);
        }
        await inputModel.tapUp(MouseButtons.left);
      }
    }
  }

  onTap() async {
    if (_touchDownOnKeyHelpTools) {
      return;
    }
    if (isNotTouchBasedDevice()) {
      return;
    }
    // Filter duplicate touch tap events on iOS (Magic Mouse issue).
    final lastPos = _lastTapDownGlobalPosition;
    if (lastPos != null && inputModel.shouldIgnoreTouchTap(lastPos)) {
      return;
    }
    if (!handleTouch) {
      // Cannot use `_lastTapDownDetails` because Flutter calls `onTapUp` before `onTap`, clearing the cached details.
      // Using `_lastTapDownPositionForMouseMode` instead.
      if (shouldBlockMouseModeEvent()) {
        return;
      }
      // Mobile, "Mouse mode"
      await inputModel.tap(MouseButtons.left);
    }
  }

  onDoubleTapDown(TapDownDetails d) async {
    lastDeviceKind = d.kind;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (handleTouch) {
      _lastPosOfDoubleTapDown = d.localPosition;
      await ffi.cursorModel.move(d.localPosition.dx, d.localPosition.dy);
    } else {
      _lastTapDownPositionForMouseMode = d.localPosition;
    }
  }

  onDoubleTap() async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (ffiModel.touchMode && ffi.cursorModel.lastIsBlocked) {
      return;
    }
    if (handleTouch &&
        !ffi.cursorModel.isInRemoteRect(_lastPosOfDoubleTapDown)) {
      return;
    }
    // Check if the position is in a blocked area when using the mouse mode.
    if (!handleTouch) {
      if (shouldBlockMouseModeEvent()) {
        return;
      }
    }
    await inputModel.tap(MouseButtons.left);
    await inputModel.tap(MouseButtons.left);
  }

  onLongPressDown(LongPressDownDetails d) async {
    if (_touchDownOnKeyHelpTools) {
      return;
    }
    lastDeviceKind = d.kind;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (handleTouch) {
      _lastPosOfDoubleTapDown = d.localPosition;
      _cacheLongPressPosition = d.localPosition;
      _cacheLongPressPositionTs = DateTime.now().millisecondsSinceEpoch;
      if (_isAndroidTouchMode) return;
      if (!ffi.cursorModel.isInRemoteRect(d.localPosition)) {
        return;
      }
      if (ffiModel.isPeerMobile) {
        await ffi.cursorModel
            .move(_cacheLongPressPosition.dx, _cacheLongPressPosition.dy);
        await inputModel.tapDown(MouseButtons.left);
      }
    } else {
      _lastTapDownPositionForMouseMode = d.localPosition;
    }
  }

  onLongPressUp() async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (_isAndroidTouchMode) return;
    if (handleTouch) {
      await inputModel.tapUp(MouseButtons.left);
    }
  }

  // for mobiles
  onLongPress() async {
    if (_touchDownOnKeyHelpTools) {
      return;
    }
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (_isAndroidTouchMode) return;
    if (!ffi.ffiModel.isPeerMobile) {
      if (handleTouch) {
        final isMoved = await ffi.cursorModel
            .move(_cacheLongPressPosition.dx, _cacheLongPressPosition.dy);
        if (!isMoved) {
          return;
        }
      } else {
        if (shouldBlockMouseModeEvent()) {
          return;
        }
      }
      await inputModel.tap(MouseButtons.right);
    } else {
      // It's better to send a message to tell the controlled device that the long press event is triggered.
      // We're now using a `TimerTask` in `InputService.kt` to decide whether to trigger the long press event.
      // It's not accurate and it's better to use the same detection logic in the controlling side.
    }
  }

  onLongPressMoveUpdate(LongPressMoveUpdateDetails d) async {
    if (!ffiModel.isPeerMobile || isNotTouchBasedDevice()) {
      return;
    }
    if (handleTouch) {
      if (!ffi.cursorModel.isInRemoteRect(d.localPosition)) {
        return;
      }
      await ffi.cursorModel.move(d.localPosition.dx, d.localPosition.dy);
    }
  }

  onDoubleFinerTapDown(TapDownDetails d) async {
    lastDeviceKind = d.kind;
    if (isNotTouchBasedDevice()) {
      return;
    }
    _doubleFinerTapPosition = d.localPosition;
    // ignore for desktop and mobile
  }

  onDoubleFinerTap(TapDownDetails d) async {
    lastDeviceKind = d.kind;
    if (isNotTouchBasedDevice()) {
      return;
    }

    // mobile mouse mode or desktop touch screen
    final isMobileMouseMode = isMobile && !ffiModel.touchMode;
    // We can't use `d.localPosition` here because it's always (0, 0) on desktop.
    final isDesktopInRemoteRect = (isDesktop || isWebDesktop) &&
        ffi.cursorModel.isInRemoteRect(_doubleFinerTapPosition);
    if (isMobileMouseMode || isDesktopInRemoteRect) {
      await inputModel.tap(MouseButtons.right);
    }
  }

  onHoldDragStart(DragStartDetails d) async {
    lastDeviceKind = d.kind;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (!handleTouch) {
      if (isSpecialHoldDragActive) return;
      await inputModel.sendMouse('down', MouseButtons.left);
    }
  }

  onHoldDragUpdate(DragUpdateDetails d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (!handleTouch) {
      if (isSpecialHoldDragActive) return;
      await ffi.cursorModel.updatePan(d.delta, d.localPosition, handleTouch);
    }
  }

  onHoldDragEnd(DragEndDetails d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (!handleTouch) {
      await inputModel.sendMouse('up', MouseButtons.left);
    }
  }

  onOneFingerPanStart(BuildContext context, DragStartDetails d) async {
    if (_touchDownOnKeyHelpTools) {
      return;
    }
    final TapDownDetails? lastTapDownDetails = _lastTapDownDetails;
    _lastTapDownDetails = null;
    lastDeviceKind = d.kind ?? lastDeviceKind;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (handleTouch) {
      if (lastTapDownDetails != null) {
        await ffi.cursorModel.move(lastTapDownDetails.localPosition.dx,
            lastTapDownDetails.localPosition.dy);
      }
      if (ffi.cursorModel.shouldBlock(d.localPosition.dx, d.localPosition.dy)) {
        return;
      }
      if (!ffi.cursorModel.isInRemoteRect(d.localPosition)) {
        return;
      }

      if (_isAndroidTouchMode) {
        return;
      }

      _touchModePanStarted = true;
      if (isDesktop || isWebDesktop) {
        ffi.cursorModel.trySetRemoteWindowCoords();
      }

      // Workaround for the issue that the first pan event is sent a long time after the start event.
      // If the time interval between the start event and the first pan event is less than 500ms,
      // we consider to use the long press position as the start position.
      //
      // TODO: We should find a better way to send the first pan event as soon as possible.
      if (DateTime.now().millisecondsSinceEpoch - _cacheLongPressPositionTs <
          500) {
        await ffi.cursorModel
            .move(_cacheLongPressPosition.dx, _cacheLongPressPosition.dy);
      }
      // In relative mouse mode, skip mouse down - only send movement via sendMobileRelativeMouseMove
      if (!inputModel.relativeMouseMode.value) {
        await inputModel.sendMouse('down', MouseButtons.left);
      }
      await ffi.cursorModel.move(d.localPosition.dx, d.localPosition.dy);
    } else {
      final offset = ffi.cursorModel.offset;
      final cursorX = offset.dx;
      final cursorY = offset.dy;
      final visible =
          ffi.cursorModel.getVisibleRect().inflate(1); // extend edges
      final size = MediaQueryData.fromView(View.of(context)).size;
      if (!visible.contains(Offset(cursorX, cursorY))) {
        await ffi.cursorModel.move(size.width / 2, size.height / 2);
      }
    }
  }

  onOneFingerPanUpdate(DragUpdateDetails d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (_isAndroidTouchMode) {
      return;
    }
    if (ffi.cursorModel.shouldBlock(d.localPosition.dx, d.localPosition.dy)) {
      return;
    }
    if (handleTouch && !_touchModePanStarted) {
      return;
    }
    // In relative mouse mode, send delta directly without position tracking.
    if (inputModel.relativeMouseMode.value) {
      await inputModel.sendMobileRelativeMouseMove(d.delta.dx, d.delta.dy);
    } else {
      await ffi.cursorModel.updatePan(d.delta, d.localPosition, handleTouch);
    }
  }

  onOneFingerPanEnd(DragEndDetails d) async {
    _touchModePanStarted = false;
    if (_isAndroidTouchMode) {
      return;
    }
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (isDesktop || isWebDesktop) {
      ffi.cursorModel.clearRemoteWindowCoords();
    }
    if (handleTouch) {
      // In relative mouse mode, skip mouse up - matches the skipped mouse down in onOneFingerPanStart
      if (!inputModel.relativeMouseMode.value) {
        await inputModel.sendMouse('up', MouseButtons.left);
      }
    }
  }

  // Reset `_touchModePanStarted` if the one-finger pan gesture is cancelled
  // or rejected by the gesture arena. Without this, the flag can remain
  // stuck in the "started" state and cause issues such as the Magic Mouse
  // double-click problem on iPad with magic mouse.
  onOneFingerPanCancel() {
    _touchModePanStarted = false;
  }

  // scale + pan event
  onTwoFingerScaleStart(ScaleStartDetails d) async {
    _lastTapDownDetails = null;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (isAndroid && !isDesktop && !isWebDesktop) {
      _scale = 1;
      _lastTwoFingerFocalPoint = d.focalPoint;
      _lastTwoFingerScrollTsUs = 0;

      // One-finger touch mode sends left-button down. Releasing it when a
      // second finger arrives prevents the old drag from being left active
      // while the gesture is converted to remote scrolling.
      if (!isSpecialHoldDragActive &&
          _touchModePanStarted &&
          handleTouch &&
          !inputModel.relativeMouseMode.value) {
        _touchModePanStarted = false;
        await inputModel.sendMouse('up', MouseButtons.left);
      }
    }
    if (isSpecialHoldDragActive) {
      // Initialize the last focal point to calculate deltas manually.
      _lastSpecialHoldDragFocalPoint = d.focalPoint;
    }
  }

  onTwoFingerScaleUpdate(ScaleUpdateDetails d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (inputModel.isViewOnly) return;

    // Raw pointer frames handle Android two-finger wheel scrolling. Keep
    // pinch zoom as a separate gesture; a pure two-finger translation keeps
    // d.scale near 1 and therefore does not alter the canvas scale.
    if (isAndroid && !isDesktop && !isWebDesktop) {
      // Forward pinch changes to the remote host.  The desktop input service
      // converts ScaleUpdate into Ctrl+wheel, matching a touchpad zoom
      // gesture.  Do not scale the RustDesk canvas locally.
      final scale = ((d.scale - _scale) * 1000).toInt();
      _scale = d.scale;
      if (scale != 0 && !widget.isCamera) {
        await bind.sessionSendPointer(
            sessionId: sessionId,
            msg: json.encode(
                PointerEventToRust(kPointerEventKindTouch, 'scale', scale)
                    .toJson()));
      }
      return;
    }

    // If in special drag mode, perform a pan instead of a scale.
    if (isSpecialHoldDragActive) {
      // Calculate delta manually to avoid the jumpy behavior.
      final delta = d.focalPoint - _lastSpecialHoldDragFocalPoint;
      _lastSpecialHoldDragFocalPoint = d.focalPoint;
      await ffi.cursorModel.updatePan(delta * 2.0, d.focalPoint, handleTouch);
      return;
    }

    if (canvasLocked) return;

    if ((isDesktop || isWebDesktop)) {
      final scale = ((d.scale - _scale) * 1000).toInt();
      _scale = d.scale;

      if (scale != 0) {
        if (widget.isCamera) return;
        await bind.sessionSendPointer(
            sessionId: sessionId,
            msg: json.encode(
                PointerEventToRust(kPointerEventKindTouch, 'scale', scale)
                    .toJson()));
      }
    } else {
      // mobile
      ffi.canvasModel.updateScale(d.scale / _scale, d.focalPoint);
      _scale = d.scale;
      ffi.canvasModel.panX(d.focalPointDelta.dx);
      ffi.canvasModel.panY(d.focalPointDelta.dy);
    }
  }

  void _resetTwoFingerScrollState() {
    _lastTwoFingerFocalPoint = Offset.zero;
    _twoFingerScrollIntegralX = 0;
    _twoFingerScrollIntegralY = 0;
    _lastTwoFingerScrollTsUs = 0;
  }

  onTwoFingerScaleCancel(ScaleEndDetails d) async {
    if (isAndroid && !isDesktop && !isWebDesktop) {
      if (!widget.isCamera) {
        await bind.sessionSendPointer(
            sessionId: sessionId,
            msg: json.encode(
                PointerEventToRust(kPointerEventKindTouch, 'scale', 0)
                    .toJson()));
      }
      _scale = 1;
      _resetTwoFingerScrollState();
      return;
    }
    if (!isSpecialHoldDragActive) {
      await inputModel.sendMouse('up', MouseButtons.left);
    }
  }

  onTwoFingerScaleEnd(ScaleEndDetails d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (isAndroid && !isDesktop && !isWebDesktop) {
      if (!widget.isCamera) {
        await bind.sessionSendPointer(
            sessionId: sessionId,
            msg: json.encode(
                PointerEventToRust(kPointerEventKindTouch, 'scale', 0)
                    .toJson()));
      }
      _scale = 1;
      _resetTwoFingerScrollState();
      return;
    }
    if ((isDesktop || isWebDesktop)) {
      if (widget.isCamera) return;
      await bind.sessionSendPointer(
          sessionId: sessionId,
          msg: json.encode(
              PointerEventToRust(kPointerEventKindTouch, 'scale', 0).toJson()));
    } else {
      // mobile
      _scale = 1;
      // No idea why we need to set the view style to "" here.
      // bind.sessionSetViewStyle(sessionId: sessionId, value: "");
    }
    if (!isSpecialHoldDragActive) {
      await inputModel.sendMouse('up', MouseButtons.left);
    }
  }

  get onHoldDragCancel => null;
  get onThreeFingerVerticalDragUpdate => isAndroid || ffi.ffiModel.isPeerAndroid
      ? null
      : (d) {
          _mouseScrollIntegral += d.delta.dy / 4;
          if (_mouseScrollIntegral > 1) {
            inputModel.scroll(1);
            _mouseScrollIntegral = 0;
          } else if (_mouseScrollIntegral < -1) {
            inputModel.scroll(-1);
            _mouseScrollIntegral = 0;
          }
        };

  makeGestures(BuildContext context) {
    return <Type, GestureRecognizerFactory>{
      // Official
      TapGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(
                  supportedDevices: _touchOnlyGestureDevices), (instance) {
        instance
          ..onTapDown = onTapDown
          ..onTapUp = onTapUp
          ..onTap = onTap;
      }),
      DoubleTapGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
              () => DoubleTapGestureRecognizer(
                  supportedDevices: _touchOnlyGestureDevices), (instance) {
        instance
          ..onDoubleTapDown = onDoubleTapDown
          ..onDoubleTap = onDoubleTap;
      }),
      LongPressGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                  supportedDevices: _touchOnlyGestureDevices), (instance) {
        instance
          ..onLongPressDown = onLongPressDown
          ..onLongPressUp = onLongPressUp
          ..onLongPress = onLongPress
          ..onLongPressMoveUpdate = onLongPressMoveUpdate;
      }),
      // Customized
      HoldTapMoveGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<HoldTapMoveGestureRecognizer>(
              () => HoldTapMoveGestureRecognizer(
                  supportedDevices: _touchOnlyGestureDevices),
              (instance) => instance
                ..onHoldDragStart = onHoldDragStart
                ..onHoldDragUpdate = onHoldDragUpdate
                ..onHoldDragCancel = onHoldDragCancel
                ..onHoldDragEnd = onHoldDragEnd),
      DoubleFinerTapGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<DoubleFinerTapGestureRecognizer>(
              () => DoubleFinerTapGestureRecognizer(
                  supportedDevices: _touchOnlyGestureDevices), (instance) {
        instance
          ..onDoubleFinerTap = onDoubleFinerTap
          ..onDoubleFinerTapDown = onDoubleFinerTapDown;
      }),
      CustomTouchGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<CustomTouchGestureRecognizer>(
              () => CustomTouchGestureRecognizer(
                  supportedDevices: _touchOnlyGestureDevices), (instance) {
        instance.onOneFingerPanStart =
            (DragStartDetails d) => onOneFingerPanStart(context, d);
        instance
          ..onOneFingerPanUpdate = onOneFingerPanUpdate
          ..onOneFingerPanEnd = onOneFingerPanEnd
          ..onOneFingerPanCancel = onOneFingerPanCancel
          ..onTwoFingerScaleStart = onTwoFingerScaleStart
          ..onTwoFingerScaleUpdate = onTwoFingerScaleUpdate
          ..onTwoFingerScaleEnd = onTwoFingerScaleEnd
          ..onTwoFingerScaleCancel = onTwoFingerScaleCancel
          ..onThreeFingerVerticalDragUpdate = onThreeFingerVerticalDragUpdate;
      }),
    };
  }
}

bool _isAndroidMobileStylus(PointerEvent event) =>
    isAndroid &&
    isMobile &&
    !isDesktop &&
    !isWebDesktop &&
    (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus);

class RawPointerMouseRegion extends StatefulWidget {
  final InputModel inputModel;
  final Widget child;
  final MouseCursor? cursor;
  final PointerEnterEventListener? onEnter;
  final PointerExitEventListener? onExit;
  final PointerDownEventListener? onPointerDown;
  final PointerUpEventListener? onPointerUp;

  RawPointerMouseRegion({
    this.onEnter,
    this.onExit,
    this.cursor,
    this.onPointerDown,
    this.onPointerUp,
    required this.inputModel,
    required this.child,
  });

  @override
  State<RawPointerMouseRegion> createState() => _RawPointerMouseRegionState();
}

class _RawPointerMouseRegionState extends State<RawPointerMouseRegion> {
  final Map<int, _PointerContact> _stylusContacts = {};
  final Set<int> _activeTouchPointers = {};

  @override
  void didUpdateWidget(RawPointerMouseRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inputModel.sessionId != widget.inputModel.sessionId) {
      _finishStylusContacts(oldWidget.inputModel);
      _activeTouchPointers.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerHover: widget.inputModel.onPointHoverImage,
      onPointerDown: (evt) {
        widget.onPointerDown?.call(evt);
        if (_isAndroidMobileStylus(evt)) {
          final pointerInputModel = widget.inputModel;
          pointerInputModel.handleMouse(
            InputModel.getMouseEventMove(),
            pointerInputModel.remoteCanvasPositionForPointer(evt),
          );
          _stylusContacts[evt.pointer] = _PointerContact(
            evt.localPosition,
            onLongPress: () {
              if (!pointerInputModel.isViewOnly) {
                unawaited(pointerInputModel.tap(MouseButtons.right));
              }
            },
          );
        } else {
          if (evt.kind == PointerDeviceKind.touch) {
            if (_activeTouchPointers.isNotEmpty) {
              _finishStylusContacts();
            }
            _activeTouchPointers.add(evt.pointer);
          }
          widget.inputModel.onPointDownImage(evt);
        }
      },
      onPointerUp: (evt) {
        widget.onPointerUp?.call(evt);
        if (_isAndroidMobileStylus(evt)) {
          final contact = _stylusContacts.remove(evt.pointer);
          if (contact != null) {
            final pointerInputModel = widget.inputModel;
            unawaited(contact
                .finish(
                    releaseDrag: () => pointerInputModel
                        .sendMouse('up', MouseButtons.left),
                    panEndPosition:
                        pointerInputModel.remoteCanvasPositionForPointer(evt))
                .then<void>((_) async {
                  if (contact.mode == _PointerContactMode.pending &&
                      !pointerInputModel.isViewOnly) {
                    await pointerInputModel.tap(MouseButtons.left);
                  }
                }).whenComplete(contact.dispose));
          }
        } else {
          if (evt.kind == PointerDeviceKind.touch) {
            _activeTouchPointers.remove(evt.pointer);
          }
          widget.inputModel.onPointUpImage(evt);
        }
      },
      onPointerCancel: (evt) {
        if (_isAndroidMobileStylus(evt)) {
          final contact = _stylusContacts.remove(evt.pointer);
          if (contact != null) {
            final pointerInputModel = widget.inputModel;
            unawaited(contact
                .finish(
                    releaseDrag: () => pointerInputModel
                        .sendMouse('up', MouseButtons.left),
                    panEndPosition:
                        pointerInputModel.remoteCanvasPositionForPointer(evt))
                .whenComplete(contact.dispose));
          }
        } else if (evt.kind == PointerDeviceKind.touch) {
          _activeTouchPointers.remove(evt.pointer);
        }
      },
      onPointerMove: (evt) {
        if (_isAndroidMobileStylus(evt)) {
          final contact = _stylusContacts[evt.pointer];
          if (contact != null && contact.isActive) {
            final pointerInputModel = widget.inputModel;
            contact.update(
              position: evt.localPosition,
              delta: evt.delta,
              panPosition:
                  pointerInputModel.remoteCanvasPositionForPointer(evt),
              inputModel: pointerInputModel,
              updateCursor: () async {
                pointerInputModel.handleMouse(
                  InputModel.getMouseEventMove(),
                  pointerInputModel.remoteCanvasPositionForPointer(evt),
                );
              },
              startPan: (position) => pointerInputModel.handlePointerEvent(
                  'touch', kMouseEventTypePanStart, position),
              updatePan: (delta) => pointerInputModel.handlePointerEvent(
                'touch',
                kMouseEventTypePanUpdate,
                Offset(delta.dx.roundToDouble(), delta.dy.roundToDouble()),
              ),
              movePointer: () async {
                if (pointerInputModel.relativeMouseMode.value) {
                  await pointerInputModel.sendMobileRelativeMouseMove(
                      evt.delta.dx, evt.delta.dy);
                } else {
                  pointerInputModel.handleMouse(
                    InputModel.getMouseEventMove(),
                    pointerInputModel.remoteCanvasPositionForPointer(evt),
                  );
                }
              },
              startDrag: () async {
                await pointerInputModel.sendMouse('down', MouseButtons.left);
              },
              updateDrag: () async {
                final mouseEvent = InputModel.getMouseEventMove();
                mouseEvent['buttons'] = kPrimaryButton;
                pointerInputModel.handleMouse(
                  mouseEvent,
                  pointerInputModel.remoteCanvasPositionForPointer(evt),
                );
              },
            );
          }
        } else {
          widget.inputModel.onPointMoveImage(evt);
        }
      },
      onPointerSignal: widget.inputModel.onPointerSignalImage,
      onPointerPanZoomStart: widget.inputModel.onPointerPanZoomStart,
      onPointerPanZoomUpdate: widget.inputModel.onPointerPanZoomUpdate,
      onPointerPanZoomEnd: widget.inputModel.onPointerPanZoomEnd,
      child: MouseRegion(
        cursor: widget.inputModel.isViewOnly
            ? MouseCursor.defer
            : (widget.cursor ?? MouseCursor.defer),
        onEnter: widget.onEnter,
        onExit: widget.onExit,
        child: widget.child,
      ),
    );
  }

  @override
  void dispose() {
    _finishStylusContacts();
    _activeTouchPointers.clear();
    super.dispose();
  }

  void _finishStylusContacts([InputModel? inputModel]) {
    final pointerInputModel = inputModel ?? widget.inputModel;
    for (final contact in _stylusContacts.values) {
      unawaited(contact
          .finish(
              releaseDrag: () => pointerInputModel.sendMouse(
                  'up', MouseButtons.left))
          .whenComplete(contact.dispose));
    }
    _stylusContacts.clear();
  }
}

class CameraRawPointerMouseRegion extends StatelessWidget {
  final InputModel inputModel;
  final Widget child;
  final PointerEnterEventListener? onEnter;
  final PointerExitEventListener? onExit;
  final PointerDownEventListener? onPointerDown;
  final PointerUpEventListener? onPointerUp;

  CameraRawPointerMouseRegion({
    this.onEnter,
    this.onExit,
    this.onPointerDown,
    this.onPointerUp,
    required this.inputModel,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerHover: (evt) {
        final offset = evt.position;
        double x = offset.dx;
        double y = max(0.0, offset.dy);
        inputModel.handlePointerDevicePos(
            kPointerEventKindMouse, x, y, true, kMouseEventTypeDefault);
      },
      onPointerDown: (evt) {
        onPointerDown?.call(evt);
      },
      onPointerUp: (evt) {
        onPointerUp?.call(evt);
      },
      child: MouseRegion(
        cursor: MouseCursor.defer,
        onEnter: onEnter,
        onExit: onExit,
        child: child,
      ),
    );
  }
}
