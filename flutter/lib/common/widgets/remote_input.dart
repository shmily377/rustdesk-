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
  static const double threshold = 10.0;
  static const int intervalUs = 18000;

  double _integralX = 0;
  double _integralY = 0;
  int _lastScrollTsUs = 0;

  Future<bool> add(Offset delta, InputModel inputModel) async {
    if (delta.dx.abs() > delta.dy.abs()) {
      _integralX += delta.dx;
      _integralY = 0;
    } else {
      _integralY += delta.dy;
      _integralX = 0;
    }

    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final elapsedUs =
        _lastScrollTsUs == 0 ? 1000000 : nowUs - _lastScrollTsUs;
    if (elapsedUs < intervalUs) return false;

    if (_integralY.abs() >= threshold) {
      final steps = min(4, (_integralY.abs() / threshold).floor());
      if (steps <= 0) return false;
      final y = _integralY.sign.toInt();
      await inputModel.scroll(y * steps);
      _integralY -= _integralY.sign * steps * threshold;
      _lastScrollTsUs = nowUs;
      return true;
    }

    if (_integralX.abs() >= threshold) {
      final steps = min(4, (_integralX.abs() / threshold).floor());
      if (steps <= 0) return false;
      final x = _integralX.sign.toInt();
      await inputModel.scroll(0, x: x * steps);
      _integralX -= _integralX.sign * steps * threshold;
      _lastScrollTsUs = nowUs;
      return true;
    }
    return false;
  }

  void reset() {
    _integralX = 0;
    _integralY = 0;
    _lastScrollTsUs = 0;
  }
}

class _StylusContact {
  _StylusContact(this.startPosition)
      : startTimeUs = DateTime.now().microsecondsSinceEpoch;

  final Offset startPosition;
  final int startTimeUs;
  final _NaturalScrollAccumulator scroll = _NaturalScrollAccumulator();
  bool scrollSent = false;
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
///   OneFingerPan -> start/end -> left down start/end
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
  Map<int, Offset>? _twoFingerTapStartPositions;
  int _twoFingerTapStartTsUs = 0;
  double _twoFingerTapMaxMovement = 0;
  bool _isTwoFingerTapCandidate = false;
  bool _twoFingerTapScrollSent = false;
  final _NaturalScrollAccumulator _singleFingerScroll =
      _NaturalScrollAccumulator();
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

  bool get _isAndroidMobileClient =>
      isAndroid && isMobile && !isDesktop && !isWebDesktop;

  bool get _isAndroidTouchMode =>
      _isAndroidMobileClient && ffiModel.touchMode;

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      _activeTouchPositions[event.pointer] = event.localPosition;
      if (_isAndroidTouchMode && _activeTouchPositions.length == 2) {
        _twoFingerTapStartPositions = Map.of(_activeTouchPositions);
        _twoFingerTapStartTsUs = DateTime.now().microsecondsSinceEpoch;
        _twoFingerTapMaxMovement = 0;
        _twoFingerTapScrollSent = false;
        _isTwoFingerTapCandidate = true;
      } else if (_activeTouchPositions.length > 2) {
        _isTwoFingerTapCandidate = false;
      }
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.kind == PointerDeviceKind.touch &&
        _activeTouchPositions.containsKey(event.pointer)) {
      _activeTouchPositions[event.pointer] = event.localPosition;
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
    if (event.kind != PointerDeviceKind.touch ||
        !_activeTouchPositions.containsKey(event.pointer)) {
      return;
    }
    _activeTouchPositions[event.pointer] = event.localPosition;
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
    _activeTouchPositions.remove(event.pointer);
    if (_activeTouchPositions.isEmpty) {
      _resetTwoFingerTapState();
    } else {
      _isTwoFingerTapCandidate = false;
    }
  }

  void _resetTwoFingerTapState() {
    _twoFingerTapStartPositions = null;
    _twoFingerTapStartTsUs = 0;
    _twoFingerTapMaxMovement = 0;
    _isTwoFingerTapCandidate = false;
    _twoFingerTapScrollSent = false;
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
    lastDeviceKind = d.kind;
    if (_isAndroidTouchMode) {
      _androidSingleFingerScrollHandled = false;
    }
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
    lastDeviceKind = d.kind;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (handleTouch) {
      _lastPosOfDoubleTapDown = d.localPosition;
      _cacheLongPressPosition = d.localPosition;
      if (!ffi.cursorModel.isInRemoteRect(d.localPosition)) {
        return;
      }
      _cacheLongPressPositionTs = DateTime.now().millisecondsSinceEpoch;
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
    if (handleTouch) {
      await inputModel.tapUp(MouseButtons.left);
    }
  }

  // for mobiles
  onLongPress() async {
    if (isNotTouchBasedDevice()) {
      return;
    }
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
        _androidSingleFingerScrollHandled = true;
        _singleFingerScroll.reset();
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
    if (_isAndroidTouchMode && _androidSingleFingerScrollHandled) {
      if (!inputModel.isViewOnly) {
        await _singleFingerScroll.add(d.delta, inputModel);
      }
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
    if (_isAndroidTouchMode && _androidSingleFingerScrollHandled) {
      _singleFingerScroll.reset();
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
    if (_isAndroidTouchMode && _androidSingleFingerScrollHandled) {
      _singleFingerScroll.reset();
    }
  }

  // scale + pan event
  onTwoFingerScaleStart(ScaleStartDetails d) async {
    _lastTapDownDetails = null;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (isAndroid && !isDesktop && !isWebDesktop) {
      if (_isAndroidTouchMode && _androidSingleFingerScrollHandled) {
        _singleFingerScroll.reset();
      }
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

    // Android: use the focal point (two-finger center) for wheel scrolling.
    // Pinch scale and canvas pan are intentionally ignored.
    if (isAndroid && !isDesktop && !isWebDesktop) {
      final delta = d.focalPoint - _lastTwoFingerFocalPoint;
      _lastTwoFingerFocalPoint = d.focalPoint;

      // Dominant-axis filtering avoids simultaneous horizontal and vertical
      // wheel events while the two-finger center moves diagonally.
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
        if (steps <= 0) return;
        // Natural direction: fingers down => content down; fingers up => content up.
        final y = _twoFingerScrollIntegralY.sign.toInt();
        _twoFingerTapScrollSent = true;
        await inputModel.scroll(y * steps);
        _twoFingerScrollIntegralY -=
            _twoFingerScrollIntegralY.sign *
                steps *
                _twoFingerScrollThreshold;
        _lastTwoFingerScrollTsUs = nowUs;
        return;
      }

      if (_twoFingerScrollIntegralX.abs() >= _twoFingerScrollThreshold) {
        final steps = min(
            4,
            (_twoFingerScrollIntegralX.abs() / _twoFingerScrollThreshold)
                .floor());
        if (steps <= 0) return;
        // Natural direction: fingers right => content right; fingers left => content left.
        final x = _twoFingerScrollIntegralX.sign.toInt();
        _twoFingerTapScrollSent = true;
        await inputModel.scroll(0, x: x * steps);
        _twoFingerScrollIntegralX =
            _twoFingerScrollIntegralX.sign *
                (_twoFingerScrollIntegralX.abs() -
                    steps * _twoFingerScrollThreshold);
        _lastTwoFingerScrollTsUs = nowUs;
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
  final Map<int, _StylusContact> _stylusContacts = {};

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerHover: widget.inputModel.onPointHoverImage,
      onPointerDown: (evt) {
        widget.onPointerDown?.call(evt);
        if (_isAndroidMobileStylus(evt)) {
          widget.inputModel.handleMouse(
            InputModel.getMouseEventMove(),
            widget.inputModel.remoteCanvasPositionForPointer(evt),
          );
          _stylusContacts[evt.pointer] = _StylusContact(evt.localPosition);
        } else {
          widget.inputModel.onPointDownImage(evt);
        }
      },
      onPointerUp: (evt) {
        widget.onPointerUp?.call(evt);
        if (_isAndroidMobileStylus(evt)) {
          final contact = _stylusContacts.remove(evt.pointer);
          if (contact != null) {
            final durationUs =
                DateTime.now().microsecondsSinceEpoch - contact.startTimeUs;
            final distance =
                (evt.localPosition - contact.startPosition).distance;
            contact.scroll.reset();
            if (!contact.scrollSent &&
                durationUs <= 250000 &&
                distance <= 20) {
              unawaited(widget.inputModel.tap(MouseButtons.left));
            }
          }
        } else {
          widget.inputModel.onPointUpImage(evt);
        }
      },
      onPointerCancel: (evt) {
        if (_isAndroidMobileStylus(evt)) {
          _stylusContacts.remove(evt.pointer)?.scroll.reset();
        }
      },
      onPointerMove: (evt) async {
        if (_isAndroidMobileStylus(evt)) {
          final contact = _stylusContacts[evt.pointer];
          if (contact != null && !widget.inputModel.isViewOnly) {
            final didScroll =
                await contact.scroll.add(evt.delta, widget.inputModel);
            contact.scrollSent = contact.scrollSent || didScroll;
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
