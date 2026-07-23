import 'package:flutter/material.dart';

/// Process-wide decoded avatar so home → settings can paint without a blank frame.
///
/// Settings uses [NoTransitionPage], so there is no route animation for Hero to
/// hide the gap. We keep the last [ImageInfo] and draw it with [RawImage].
class AvatarDecodedCache {
  AvatarDecodedCache._();

  static String? _url;
  static ImageInfo? _info;
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static ImageInfo? peek(String url) {
    final u = url.trim();
    if (u.isEmpty || u != _url) return null;
    return _info;
  }

  static void put(String url, ImageInfo info) {
    final u = url.trim();
    if (u.isEmpty) return;
    if (_url == u && _info != null) return;
    _info?.dispose();
    _url = u;
    _info = info.clone();
    changes.value++;
  }

  static void clear() {
    final hadValue = _info != null || _url != null;
    _info?.dispose();
    _info = null;
    _url = null;
    if (hadValue) changes.value++;
  }
}

/// Network avatar that paints from [AvatarDecodedCache] when available (no flash).
class UserAvatarImage extends StatefulWidget {
  final String imageUrl;
  final String cacheKey;
  final double size;
  final BorderRadius? borderRadius;
  final Widget errorWidget;

  const UserAvatarImage({
    super.key,
    required this.imageUrl,
    required this.cacheKey,
    required this.size,
    required this.errorWidget,
    this.borderRadius,
  });

  @override
  State<UserAvatarImage> createState() => _UserAvatarImageState();
}

class _UserAvatarImageState extends State<UserAvatarImage> {
  ImageStream? _stream;
  late final ImageStreamListener _listener;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _listener = ImageStreamListener(_onImage, onError: _onError);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant UserAvatarImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _failed = false;
      _resolve(force: true);
    }
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  void _onImage(ImageInfo info, bool synchronousCall) {
    AvatarDecodedCache.put(widget.imageUrl, info);
    if (mounted) setState(() => _failed = false);
  }

  void _onError(Object _, StackTrace? __) {
    if (mounted) setState(() => _failed = true);
  }

  void _resolve({bool force = false}) {
    final url = widget.imageUrl.trim();
    _stream?.removeListener(_listener);
    _stream = null;
    if (url.isEmpty) return;

    // Reuse decoded bitmap; still re-listen when URL forced-changed.
    if (!force && AvatarDecodedCache.peek(url) != null) return;

    final provider = NetworkImage(url);
    final stream = provider.resolve(
      createLocalImageConfiguration(
        context,
        size: Size(widget.size, widget.size),
      ),
    );
    _stream = stream;
    stream.addListener(_listener);
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.imageUrl.trim();
    final radius =
        widget.borderRadius ?? BorderRadius.circular(widget.size / 2);
    final loadingIndicatorSize =
        (widget.size * 0.35).clamp(16.0, 28.0).toDouble();

    return ValueListenableBuilder<int>(
      valueListenable: AvatarDecodedCache.changes,
      builder: (context, _, __) {
        final cached = AvatarDecodedCache.peek(url);
        final Widget child;
        if (cached != null) {
          child = RawImage(
            image: cached.image,
            scale: cached.scale,
            width: widget.size,
            height: widget.size,
            fit: BoxFit.cover,
          );
        } else if (_failed || url.isEmpty) {
          child = widget.errorWidget;
        } else {
          child = Center(
            child: SizedBox.square(
              dimension: loadingIndicatorSize,
              child: const CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        return ClipRRect(
          borderRadius: radius,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: child,
          ),
        );
      },
    );
  }
}
