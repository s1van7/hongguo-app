import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../../playback_session.dart';
import '../app_scope.dart';
import '../downloads/download_actions.dart';
import '../shell/immersive.dart';
import '../shell/window_caption.dart';
import '../theme/app_theme.dart';
import '../widgets/focus_ring.dart';
import '../widgets/follow_button.dart';
import 'episode_grid.dart';
import 'mini_player.dart';
import 'playback_handle.dart';
import 'player_surface.dart';
import 'window_fullscreen.dart';

const _panelWidth = 320.0;

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.store,
    required this.handle,
    this.padFullscreen,
    this.onWindowFullscreen,
    this.onMiniWindow,
  });
  final LocalStore store;
  final PlaybackHandle handle;
  final ValueNotifier<bool>? padFullscreen;
  final ValueChanged<bool>? onWindowFullscreen;
  final VoidCallback? onMiniWindow;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  final _focus = FocusNode(debugLabel: 'player');
  final _surfaceKey = GlobalKey();
  final _hint = ValueNotifier('');
  final _selected = <int>{};
  Timer? _hintTimer;
  late bool _wide = !_touch && widget.store.playerWide;
  bool _windowFullscreen = false;
  bool _seekHeld = false;
  bool _selecting = false;
  bool _drawer = false;

  PlaybackSession get _playback => widget.handle.session;
  Drama get _drama => _playback.detail.drama;
  List<Episode> get _episodes => _playback.detail.episodes;
  bool get _touch => widget.padFullscreen != null;
  bool get _fullscreen => widget.padFullscreen?.value ?? _windowFullscreen;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hintTimer?.cancel();
    _hint.dispose();
    _focus.dispose();
    if (_windowFullscreen) {
      widget.onWindowFullscreen?.call(false);
      unawaited(_setFullScreen(false));
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _playback.setForeground(playerVisible(state));
  }

  bool get _canDownload =>
      AppScope.of(context).repository.supportsDownloads &&
      widget.store.canDownload;

  bool get _roomy => MediaQuery.sizeOf(context).width - 32 >= 840;

  Future<void> _setFullScreen(bool value) => setWindowFullScreen(value);

  Future<void> _toggleFullscreen() async {
    if (widget.padFullscreen case final pad?) {
      pad.value = !pad.value;
      _focus.requestFocus();
      return;
    }
    final next = !_windowFullscreen;
    widget.onWindowFullscreen?.call(next);
    setState(() => _windowFullscreen = next);
    _focus.requestFocus();
    await _setFullScreen(next);
  }

  void _toggleWide() {
    setState(() => _wide = !_wide);
    _focus.requestFocus();
    unawaited(widget.store.setPlayerWide(_wide).catchError((Object _) {}));
  }

  bool get _filled => _fullscreen || _wide && !_selecting;

  void _back() {
    if (_fullscreen) {
      unawaited(_toggleFullscreen());
    } else if (_selecting) {
      _endSelection();
    } else if (_drawer) {
      setState(() => _drawer = false);
      _focus.requestFocus();
    } else if (_wide) {
      _toggleWide();
    } else {
      unawaited(Navigator.maybePop(context));
    }
  }

  /// 选集浮层：画面永远是最大的，选集需要时再滑出来盖住右侧。
  void _toggleDrawer() {
    if (!_roomy) {
      unawaited(_showEpisodes());
      return;
    }
    setState(() => _drawer = !_drawer);
    _focus.requestFocus();
  }

  void _startSelection() {
    setState(() {
      _selecting = true;
      _selected.clear();
    });
    _focus.requestFocus();
  }

  void _endSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    _focus.requestFocus();
  }

  void _download() {
    final episodes = [
      for (final index in _selected.toList()..sort()) _episodes[index],
    ];
    _endSelection();
    unawaited(
      downloadEpisodes(context, widget.store, _playback.detail, episodes),
    );
  }

  void _say(String text) {
    _hintTimer?.cancel();
    _hint.value = text;
    _hintTimer = Timer(const Duration(milliseconds: 1200), () {
      _hint.value = '';
    });
  }

  void _seek(int seconds) {
    final target = _playback.seekBy(seconds);
    if (target == null) return;
    _say('${seconds > 0 ? '快进至' : '后退至'} ${formatClock(target)}');
  }

  void _volume(double volume) =>
      _say(volume == 0 ? '已静音' : '音量 ${volume.round()}%');

  void _episode(int direction) {
    final target = _playback.index + direction;
    if (target < 0) return _say('已经是第一集');
    if (target >= _episodes.length) return _say('已经是最后一集');
    unawaited(_playback.play(target));
    _say('第 ${_episodes[target].number} 集');
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    final down = event is KeyDownEvent;
    if (key == LogicalKeyboardKey.arrowRight && event is KeyUpEvent) {
      if (!_seekHeld) return KeyEventResult.ignored;
      _seekHeld = false;
      if (!_playback.endBoost()) _seek(5);
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    // Shift + ↑↓ 留给音量，其余修饰键直接放行给系统
    if (keyboard.isShiftPressed &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      if (down) {
        _volume(
          _playback.changeVolume(key == LogicalKeyboardKey.arrowUp ? 5 : -5),
        );
      }
      return KeyEventResult.handled;
    }
    if (keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (down) _back();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f11) {
      if (down) unawaited(_toggleFullscreen());
      return KeyEventResult.handled;
    }
    if (!_focus.hasPrimaryFocus) return KeyEventResult.ignored;
    switch (key) {
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        if (down) unawaited(_toggleFullscreen());
      case LogicalKeyboardKey.space || LogicalKeyboardKey.mediaPlayPause:
        if (down) _playback.togglePlayback();
      case LogicalKeyboardKey.arrowRight:
        if (down) {
          _seekHeld = true;
          _playback.beginBoost();
        }
      case LogicalKeyboardKey.arrowLeft:
        if (down) _seek(-5);
      case LogicalKeyboardKey.arrowUp:
        if (down) _episode(-1);
      case LogicalKeyboardKey.arrowDown:
        if (down) _episode(1);
      case LogicalKeyboardKey.keyM:
        if (down) _volume(_playback.toggleMute());
      case LogicalKeyboardKey.mediaTrackNext || LogicalKeyboardKey.pageDown:
        if (down) _episode(1);
      case LogicalKeyboardKey.mediaTrackPrevious || LogicalKeyboardKey.pageUp:
        if (down) _episode(-1);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark
        ? theme
        : AppTheme.build(
            theme.colorScheme.primary,
            Brightness.dark,
            television: false,
          );
    final surface = Theme(
      data: dark,
      child: ClipRRect(
        key: _surfaceKey,
        borderRadius: BorderRadius.circular(_filled ? 0 : 16),
        child: ColoredBox(
          color: Colors.black,
          child: PlayerSurface(
            handle: widget.handle,
            hint: _hint,
            touch: _touch,
            fullscreen: _fullscreen,
            wide: _wide,
            onFullscreen: () => unawaited(_toggleFullscreen()),
            onWide: _toggleWide,
            onVolume: (delta) => _volume(_playback.changeVolume(delta)),
            onMiniWindow: widget.onMiniWindow,
            onEpisodes: _toggleDrawer,
            onSurface: _focus.requestFocus,
          ),
        ),
      ),
    );
    final drawer = _roomy && (_drawer || _selecting);
    // 沉浸式：侧栏与窗口按钮浮在画面上，页面整体铺满，顶部栏透明浮着
    final shell = shellVisibleFrom(context);
    final rail = _fullscreen || !shell ? 0.0 : railInsetOf(context);
    final caption = _fullscreen ? 0.0 : captionInset;
    return ImmersivePage(
      child: PopScope(
        canPop: !_fullscreen && !_selecting && !_wide && !_drawer,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _back();
        },
        child: KeyboardControls(
          child: Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _key,
            child: Theme(
              data: dark,
              child: Scaffold(
                backgroundColor: Colors.black,
                body: Stack(
                  children: [
                    Positioned.fill(
                      child: _filled
                          ? Padding(
                              padding: EdgeInsets.only(left: rail),
                              child: SafeArea(child: surface),
                            )
                          : Builder(
                              builder: (context) => ListenableBuilder(
                                listenable: _playback,
                                builder: (context, _) => Padding(
                                  // 画面直接铺满窗口，标题栏浮在上面，选集按需滑出
                                  padding: EdgeInsets.fromLTRB(
                                    rail + 12,
                                    12 + caption,
                                    12,
                                    12,
                                  ),
                                  child: Stack(
                                    children: [
                                      Positioned.fill(child: surface),
                                      Positioned(
                                        left: 0,
                                        right: 0,
                                        top: 0,
                                        child: _header(context),
                                      ),
                                      if (drawer)
                                        Positioned(
                                          top: 0,
                                          right: 0,
                                          bottom: 0,
                                          width: _panelWidth,
                                          child: _panel(context),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                    ),
                    // 播放页被推到根导航时盖住了外壳，窗口按钮得自己补一条
                    if (!shell && appCaptionEnabled && !_fullscreen)
                      const Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        child: WindowCaptionBar(overlay: true),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showEpisodes() async {
    if (_episodes.isEmpty) return;
    final current = _playback.index;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: const Color(0xFF16161A),
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: SizedBox(
          width: 420,
          height: 520,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_drama.title} · 共 ${_episodes.length} 集',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: const Icon(Icons.close_rounded),
                      color: Colors.white70,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Theme(
                  data: Theme.of(context).copyWith(
                    brightness: Brightness.dark,
                    colorScheme: ColorScheme.fromSeed(
                      seedColor: Theme.of(context).colorScheme.primary,
                      brightness: Brightness.dark,
                    ),
                  ),
                  child: EpisodeGrid(
                    episodes: _episodes,
                    current: current,
                    selecting: false,
                    selected: const {},
                    onSelectionChanged: () {},
                    onPick: (index) {
                      Navigator.pop(dialogContext);
                      if (index != _playback.index) {
                        unawaited(_playback.play(index));
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    _focus.requestFocus();
  }

  Widget _header(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xA6000000), Color(0x00000000)],
        ),
      ),
      child: SizedBox(
        height: 64,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 10, 8),
          child: Row(
            spacing: 8,
            children: [
              _round(Icons.arrow_back_rounded, '返回', _back),
              Expanded(
                child: Text(
                  '${_drama.title} · 第 ${_playback.episode.number} 集',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    shadows: [Shadow(color: Color(0x99000000), blurRadius: 4)],
                  ),
                ),
              ),
              if (_selecting) ...[
                Text(
                  '已选 ${_selected.length} 集',
                  style: TextStyle(
                    fontSize: 14,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                TextButton(onPressed: _endSelection, child: const Text('取消')),
                TextButton(
                  onPressed: () => setState(() {
                    _selected.length == _episodes.length
                        ? _selected.clear()
                        : _selected.addAll(
                            List.generate(_episodes.length, (index) => index),
                          );
                  }),
                  child: Text(
                    _selected.length == _episodes.length ? '取消全选' : '全选',
                  ),
                ),
                FilledButton.icon(
                  onPressed: _selected.isEmpty ? null : _download,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('下载'),
                ),
              ] else ...[
                FollowPill(
                  store: widget.store,
                  drama: _drama,
                  radius: 10,
                  onToggled: _focus.requestFocus,
                ),
                if (_roomy)
                  _round(
                    Icons.format_list_numbered_rounded,
                    _drawer ? '收起选集' : '选集',
                    _toggleDrawer,
                    active: _drawer,
                  ),
                _round(
                  Icons.download_rounded,
                  '下载选集',
                  _canDownload && _roomy ? _startSelection : null,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 浮在画面上的圆形按钮：黑色半透明底，亮画面上也看得清。
  Widget _round(
    IconData icon,
    String tooltip,
    VoidCallback? onPressed, {
    bool active = false,
  }) => Material(
    color: active
        ? Colors.white.withValues(alpha: .26)
        : Colors.black.withValues(alpha: .3),
    shape: const CircleBorder(),
    clipBehavior: Clip.antiAlias,
    child: IconButton(
      onPressed: onPressed,
      icon: Icon(icon),
      iconSize: 21,
      color: Colors.white,
      disabledColor: Colors.white.withValues(alpha: .38),
      tooltip: tooltip,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(40),
        padding: EdgeInsets.zero,
      ),
    ),
  );

  Widget _panel(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 10, top: 58),
      child: Material(
        color: colors.surfaceContainerLow.withValues(alpha: .97),
        elevation: 16,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 6, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '选集 · 共 ${_episodes.length} 集',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '收起选集',
                    onPressed: () => setState(() => _drawer = false),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
            ),
            Expanded(child: _episodeList()),
          ],
        ),
      ),
    );
  }

  Widget _episodeList() => EpisodeGrid(
    episodes: _episodes,
    current: _playback.index,
    selecting: _selecting,
    selected: _selected,
    onSelectionChanged: () => setState(() {}),
    onPick: (index) {
      if (index != _playback.index) unawaited(_playback.play(index));
    },
  );
}
