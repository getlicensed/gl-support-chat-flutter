import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'common.dart';

/// A photo in the thread is this wide, and decoded at this width: less to
/// decode and to hold than the photo's own (up to 2048 pixels).
const threadPhotoWidth = 240.0;

/// The thread's copy of [image]: decoded at the width it is drawn. The
/// viewer and its flight draw it under the whole picture until that has
/// decoded, so neither is ever empty.
ImageProvider threadThumb(ImageProvider image, double devicePixelRatio) => ResizeImage(image, width: (threadPhotoWidth * devicePixelRatio).round());

/// A photo of the thread, as the viewer shows it.
class ViewerPhoto {
  const ViewerPhoto({required this.tag, required this.name, this.image, this.load, this.size});

  /// The thumbnail's Hero tag — the attachment, or the message on its way —
  /// compared by identity: one photo, one tag, whatever its name or address.
  final Object tag;

  /// The file's name, shown over the photo.
  final String name;

  /// The whole picture, when it can be drawn now.
  final ImageProvider? image;

  /// Fetches it otherwise: the customer's own photo, with their token.
  final Future<ImageProvider> Function()? load;

  /// Its size in pixels, when the server said it.
  final Size? size;
}

/// The flight between a photo in the thread and the viewer: the picture,
/// cut to the box as it grows from the thread's crop to its own shape, its
/// corners from the thread's to none.
HeroFlightShuttleBuilder photoFlight(ImageProvider image, double devicePixelRatio) =>
    (flight, animation, direction, from, to) => AnimatedBuilder(
          key: const ValueKey<String>('photo-flight'),
          animation: animation,
          builder: (_, __) => ClipRRect(
            borderRadius: BorderRadius.circular(PhotoViewer.threadRadius * (1 - animation.value)),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image(image: threadThumb(image, devicePixelRatio), fit: BoxFit.cover, gaplessPlayback: true),
                Image(image: image, fit: BoxFit.cover, gaplessPlayback: true),
              ],
            ),
          ),
        );

/// The viewer's route: over everything, the messenger's sheet too. It fades
/// its black in and out; the photo itself flies from the thread and back
/// (a Hero). Its whole time with less motion asked for too, as the rest of
/// the messenger (see [fullTime]).
Route<void> photoViewerRoute({required RouteSettings settings, required WidgetBuilder builder}) => _PhotoRoute(settings: settings, builder: builder);

class _PhotoRoute extends PageRoute<void> {
  _PhotoRoute({required super.settings, required this.builder});

  final WidgetBuilder builder;

  @override
  bool get opaque => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 250);

  @override
  AnimationController createAnimationController() => AnimationController(
        duration: transitionDuration,
        reverseDuration: reverseTransitionDuration,
        debugLabel: debugLabel,
        vsync: navigator!,
        animationBehavior: AnimationBehavior.preserve,
      );

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) => builder(context);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) => child;
}

/// The thread's photos, full screen, one at a time, from [initial]: swipe
/// between them; pinch, or tap twice, to zoom; drag down to close, the black
/// fading as it goes; or Close. The file's name over it. On iOS and Android
/// alike.
class PhotoViewer extends StatefulWidget {
  const PhotoViewer({super.key, required this.photos, required this.initial});

  final List<ViewerPhoto> photos;
  final int initial;

  /// A drag down past this closes it, or a flick down faster than
  /// [closeSpeed]; less, and the photo springs back.
  static const closeDistance = 120.0;
  static const closeSpeed = 700.0;

  /// How far a drag takes the black to nothing.
  static const fadeDistance = 360.0;

  /// The thread's photos' corners, which the flight takes away.
  static const threadRadius = 16.0;

  /// Tapped twice, it zooms to this.
  static const doubleTapScale = 2.5;
  static const maxScale = 4.0;
  static const zoomTime = Duration(milliseconds: 250);

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> with SingleTickerProviderStateMixin {
  late final PageController _pages = PageController(initialPage: widget.initial);
  late int _page = widget.initial;

  /// The photo on screen is zoomed in: a drag pans it, rather than turn the
  /// page or close the viewer.
  bool _zoomed = false;

  /// How far the photo has been dragged down (up, below 0).
  double _drag = 0;
  double _dragFrom = 0;
  late final AnimationController _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 250), animationBehavior: AnimationBehavior.preserve)
    ..addListener(() => setState(() => _drag = _dragFrom * (1 - Curves.easeOutCubic.transform(_back.value))));

  @override
  void dispose() {
    _back.dispose();
    _pages.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).maybePop();

  void _dragStart(DragStartDetails _) => _back.stop();

  void _dragUpdate(DragUpdateDetails d) {
    final dy = d.primaryDelta ?? 0;
    // Up, it follows reluctantly: only down closes it.
    setState(() => _drag += _drag + dy < 0 ? dy * 0.3 : dy);
  }

  void _dragEnd(DragEndDetails d) {
    final speed = d.primaryVelocity ?? 0;
    if (_drag > PhotoViewer.closeDistance || (_drag > 0 && speed > PhotoViewer.closeSpeed)) {
      _close();
      return;
    }
    _dragFrom = _drag;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context)?.animation ?? kAlwaysCompleteAnimation;
    final fade = (1 - _drag.abs() / PhotoViewer.fadeDistance).clamp(0.0, 1.0);
    final photo = widget.photos[_page];
    final count = widget.photos.length;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: statusBarStyle(darkIcons: false),
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedBuilder(
                animation: route,
                builder: (_, __) => ColoredBox(color: Color.fromARGB((255 * route.value * fade).round(), 0, 0, 0)),
              ),
            ),
            Positioned.fill(
              child: GestureDetector(
                // Zoomed in, a drag is the photo's own: it pans.
                onVerticalDragStart: _zoomed ? null : _dragStart,
                onVerticalDragUpdate: _zoomed ? null : _dragUpdate,
                onVerticalDragEnd: _zoomed ? null : _dragEnd,
                child: Transform.translate(
                  offset: Offset(0, _drag),
                  // Shown as it flies in; there at once when it has no
                  // photo in the thread to fly from.
                  child: FadeTransition(
                    opacity: route,
                    child: PageView.builder(
                      controller: _pages,
                      physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
                      itemCount: count,
                      onPageChanged: (i) => setState(() {
                        _page = i;
                        _zoomed = false;
                      }),
                      itemBuilder: (context, i) => _ZoomablePhoto(
                        key: ObjectKey(widget.photos[i].tag),
                        photo: widget.photos[i],
                        label: count > 1 ? 'Photo ${i + 1} of $count, ${widget.photos[i].name}' : 'Photo, ${widget.photos[i].name}',
                        onZoom: (zoomed) {
                          if (i == _page && zoomed != _zoomed) setState(() => _zoomed = zoomed);
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: AnimatedBuilder(
                animation: route,
                builder: (_, child) => Opacity(opacity: (route.value * fade).clamp(0.0, 1.0), child: child),
                child: _Bar(name: photo.name, place: count > 1 ? '${_page + 1} of $count' : null, onClose: _close),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Over the photo's top: Close, the file's name, and where it is in the
/// thread's photos — on a shade, so it reads over a light photo too.
class _Bar extends StatelessWidget {
  const _Bar({required this.name, required this.place, required this.onClose});
  final String name;
  final String? place;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x99000000), Color(0x00000000)]),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 16, 20),
          child: Row(
            children: [
              Semantics(
                button: true,
                label: 'Close',
                excludeSemantics: true,
                child: Material(
                  type: MaterialType.transparency,
                  child: SizedBox.square(
                    dimension: RoundIconButton.minTarget,
                    child: Pressable(
                      onTap: onClose,
                      onBrand: true,
                      shape: const CircleBorder(),
                      inner: const Size.square(36),
                      child: Center(
                        child: Ink(
                          width: 36,
                          height: 36,
                          decoration: const BoxDecoration(color: Color(0x66000000), shape: BoxShape.circle),
                          child: const Icon(Icons.close, size: 20, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white)),
              ),
              if (place != null) ...[
                const SizedBox(width: 12),
                Text(place!, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.white)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One photo, at its own shape in the middle of the screen: pinch it, or
/// tap twice where to look, to zoom in (to 2.5×, up to 4×); twice again,
/// back. It is the end of the flight from the thread.
class _ZoomablePhoto extends StatefulWidget {
  const _ZoomablePhoto({super.key, required this.photo, required this.label, required this.onZoom});

  final ViewerPhoto photo;
  final String label;
  final ValueChanged<bool> onZoom;

  @override
  State<_ZoomablePhoto> createState() => _ZoomablePhotoState();
}

class _ZoomablePhotoState extends State<_ZoomablePhoto> with SingleTickerProviderStateMixin {
  final _view = TransformationController();
  late final AnimationController _zoom = AnimationController(vsync: this, duration: PhotoViewer.zoomTime, animationBehavior: AnimationBehavior.preserve)
    ..addListener(() {
      final to = _zoomTo;
      if (to != null) _view.value = to.value;
    });
  Animation<Matrix4>? _zoomTo;
  Offset _tappedAt = Offset.zero;
  bool _zoomed = false;

  ImageProvider? _image;
  bool _failed = false;

  /// The picture's own shape, once known.
  double? _aspect;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _view.addListener(_scaled);
    final size = widget.photo.size;
    if (size != null && size.width > 0 && size.height > 0) _aspect = size.width / size.height;
    _image = widget.photo.image;
    final load = widget.photo.load;
    if (_image == null && load != null) {
      load().then((image) {
        if (!mounted) return;
        setState(() => _image = image);
        _measure();
      }, onError: (Object _) {
        if (mounted) setState(() => _failed = true);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _measure();
  }

  @override
  void dispose() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _view
      ..removeListener(_scaled)
      ..dispose();
    _zoom.dispose();
    super.dispose();
  }

  /// The picture's shape, from the thread's copy (decoded already, so at
  /// once) when the server did not say it.
  void _measure() {
    final image = _image;
    if (_aspect != null || image == null || _stream != null) return;
    final stream = _stream = threadThumb(image, MediaQuery.devicePixelRatioOf(context)).resolve(createLocalImageConfiguration(context));
    final listener = _listener = ImageStreamListener((info, _) {
      final aspect = info.image.width / info.image.height;
      if (_resolving) {
        _aspect = aspect;
      } else if (mounted) {
        setState(() => _aspect = aspect);
      }
    }, onError: (Object _, StackTrace? __) {});
    _resolving = true;
    stream.addListener(listener);
    _resolving = false;
  }

  void _scaled() {
    final zoomed = _view.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) return;
    _zoomed = zoomed;
    widget.onZoom(zoomed);
  }

  void _doubleTap() {
    const s = PhotoViewer.doubleTapScale;
    // Zoomed in about the point tapped: it stays under the finger.
    final to = _zoomed ? Matrix4.identity() : (Matrix4.diagonal3Values(s, s, 1)..setTranslationRaw(-_tappedAt.dx * (s - 1), -_tappedAt.dy * (s - 1), 0));
    _zoomTo = Matrix4Tween(begin: _view.value.clone(), end: to).animate(CurvedAnimation(parent: _zoom, curve: Curves.easeOutCubic));
    _zoom.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final Widget picture;
    if (image == null) {
      picture = ColoredBox(
        color: const Color(0xFF1F2023),
        child: _failed ? const Center(child: Icon(Icons.broken_image_outlined, color: Colors.white, size: 32)) : null,
      );
    } else {
      // The thread's copy until the whole picture has decoded, then it.
      picture = Stack(
        fit: StackFit.expand,
        children: [
          Image(image: threadThumb(image, dpr), fit: BoxFit.contain, gaplessPlayback: true),
          Image(image: image, fit: BoxFit.contain, gaplessPlayback: true),
        ],
      );
    }
    return Semantics(
      image: true,
      label: widget.label,
      child: GestureDetector(
        onDoubleTapDown: (d) => _tappedAt = d.localPosition,
        onDoubleTap: _doubleTap,
        child: InteractiveViewer(
          transformationController: _view,
          maxScale: PhotoViewer.maxScale,
          child: SizedBox.expand(
            child: Center(
              child: AspectRatio(
                aspectRatio: _aspect ?? 4 / 3,
                child: Hero(
                  tag: widget.photo.tag,
                  flightShuttleBuilder: image == null ? null : photoFlight(image, dpr),
                  child: picture,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
