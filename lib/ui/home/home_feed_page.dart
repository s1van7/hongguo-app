import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../../core_bridge.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../playback_preferences.dart';
import '../../playback_session.dart';
import '../app_scope.dart';
import '../detail/detail_page.dart';
import '../explore/source_actions.dart';
import '../player/playback_handle.dart';
import '../player/playback_page.dart';
import '../player/player_video.dart';
import '../shell/app_shell.dart';
import '../shell/window_caption.dart';
import '../widgets/cover_image.dart';
import '../widgets/follow_button.dart';
import '../widgets/status_view.dart';

/// 桌面/平板外壳把侧栏浮在画面之上，这里给它留出位置。
double _railInsetOf(BuildContext context) {
  final form = AppScope.formFactorOf(context);
  return form == FormFactor.window || form == FormFactor.pad ? 74 : 0;
}

/// 桌面端窗口按钮浮在画面顶部，顶部内容让开这一条。
double get _captionInset => appCaptionEnabled ? kAppCaptionHeight : 0;

class HomeFeedPage extends StatefulWidget {
  const HomeFeedPage({
    super.key,
    required this.store,
    this.entryFocus,
    this.onExitUp,
  });

  final LocalStore store;
  final FocusNode? entryFocus;
  final VoidCallback? onExitUp;

  @override
  State<HomeFeedPage> createState() => HomeFeedPageState();
}

class HomeFeedPageState extends State<HomeFeedPage>
    with WidgetsBindingObserver {
  static const _recommendCategory = CatalogCategory('', '推荐');
  static const _maxDetailCache = 48;

  final _pageController = PageController();
  final _items = <Drama>[];
  final _seenIds = <String>{};
  final _details = LinkedHashMap<String, DramaDetail>();
  final _detailTasks = <String, Future<DramaDetail>>{};
  final _resumeStates = <String, ({int index, double position})>{};
  late final FocusNode _ownFocus = FocusNode();

  AppRepository? _repository;
  String _sourceId = '';
  String _categoryId = '';
  List<CatalogCategory> _categories = const [_recommendCategory];
  int _currentIndex = 0;
  int _catalogPage = 1;
  bool _hasMore = true;
  bool _initialLoading = true;
  bool _refreshing = false;
  bool _loadingMore = false;
  String? _feedError;

  PlaybackHandle? _activeHandle;
  String? _activeKey;
  String? _activeDetailError;
  bool _resolvingDetail = false;
  bool _muted = false;
  bool _appResumed = true;
  bool _lastForeground = true;

  int _feedEpoch = 0;
  int _activationToken = 0;
  Timer? _settleTimer;
  Timer? _wheelCooldown;
  double _wheelAccum = 0;

  /// 累积到这么多像素就翻一页。鼠标滚轮一格是 100，触控板是小增量。
  static const double _wheelStep = 24;
  Timer? _heartTimer;
  StreamSubscription<bool>? _completedSub;
  Offset? _doubleTapPosition;
  Key _burstKey = UniqueKey();
  bool _showHeartBurst = false;

  FocusNode get _focusNode => widget.entryFocus ?? _ownFocus;
  String _dramaKey(Drama d) => '${d.source}:${d.id}';

  bool get _effectiveForeground =>
      mounted &&
      _appResumed &&
      ShellForeground.of(context) &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.store.addListener(_onStoreChanged);
    // 桌面端方向键在硬件层先接住，避免被按钮/滚动/焦点遍历吃掉
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final repo = AppScope.of(context).repository;
    if (_repository != repo) {
      _repository?.catalogUpdates.removeListener(_onCatalogUpdated);
      _repository = repo..catalogUpdates.addListener(_onCatalogUpdated);
      _sourceId = widget.store.source;
      unawaited(_reloadAll(force: false));
    }
    _syncForeground();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (_appResumed != resumed) {
      _appResumed = resumed;
      _syncForeground();
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    WidgetsBinding.instance.removeObserver(this);
    widget.store.removeListener(_onStoreChanged);
    _repository?.catalogUpdates.removeListener(_onCatalogUpdated);
    _settleTimer?.cancel();
    _wheelCooldown?.cancel();
    _heartTimer?.cancel();
    unawaited(_completedSub?.cancel());
    _disposeActiveHandle(save: true);
    _pageController.dispose();
    _ownFocus.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    if (widget.store.source != _sourceId) {
      _sourceId = widget.store.source;
      _categoryId = '';
      _categories = const [_recommendCategory];
      unawaited(_reloadAll(force: false));
    } else {
      setState(() {});
    }
  }

  void _onCatalogUpdated() {
    if (!mounted) return;
    if (widget.store.source != _sourceId || _items.isEmpty) {
      _sourceId = widget.store.source;
      unawaited(_reloadAll(force: false));
    }
  }

  void _syncForeground() {
    final visible = _effectiveForeground;
    if (_lastForeground == visible) return;
    _lastForeground = visible;
    if (_activeHandle != null) {
      _activeHandle!.session.setForeground(visible);
    } else if (visible && _items.isNotEmpty && !_initialLoading) {
      _scheduleActivate(_currentIndex, immediate: true);
    }
  }

  void reselect() => unawaited(refresh());
  Future<void> refresh() => _reloadAll(force: true);

  Future<void> _reloadAll({required bool force}) async {
    final repo = _repository;
    if (repo == null) return;
    final epoch = ++_feedEpoch;
    _settleTimer?.cancel();
    _disposeActiveHandle(save: true);
    unawaited(repo.cancelPreload());

    if (_sourceId.isEmpty) {
      setState(() {
        _items.clear();
        _seenIds.clear();
        _initialLoading = false;
        _feedError = null;
      });
      return;
    }

    // 已经有内容时刷新不清屏：先留着当前这屏，等新推荐回来再整体换掉，
    // 只在顶部给一条细进度条，避免每次点首页都闪一下黑屏。
    final keepVisible = force && _items.isNotEmpty;
    setState(() {
      _initialLoading = !keepVisible;
      _refreshing = keepVisible;
      _loadingMore = false;
      _feedError = null;
      _activeDetailError = null;
      _currentIndex = 0;
      _catalogPage = 1;
      _hasMore = true;
    });

    if (_categories.length <= 1) {
      unawaited(_loadCategories(repo, _sourceId, epoch, force: force));
    }

    try {
      final page = await _fetchFeedPage(
        repo: repo,
        sourceId: _sourceId,
        categoryId: _categoryId,
        more: false,
        page: 1,
        force: force,
      );
      if (!mounted || epoch != _feedEpoch) return;
      _items.clear();
      _seenIds.clear();
      for (final item in page.items) {
        if (_seenIds.add(_dramaKey(item))) _items.add(item);
      }
      _hasMore =
          page.hasMore ||
          (SourceSite.byId(_sourceId).recommends && _items.isNotEmpty);
      setState(() {
        _initialLoading = false;
        _refreshing = false;
      });
      if (_pageController.hasClients) _pageController.jumpToPage(0);
      if (_items.isNotEmpty) _scheduleActivate(0, immediate: true);
    } catch (e) {
      if (!mounted || epoch != _feedEpoch) return;
      final message = _errorMessage(e);
      setState(() {
        _initialLoading = false;
        _refreshing = false;
        _feedError = message;
      });
      if (_items.isNotEmpty) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text('刷新推荐失败：$message')));
      }
    }
  }

  Future<void> _loadCategories(
    AppRepository repo,
    String sourceId,
    int epoch, {
    required bool force,
  }) async {
    try {
      final fetched = await repo.categories(sourceId, force: force);
      if (!mounted || epoch != _feedEpoch || sourceId != _sourceId) return;
      setState(() {
        _categories = [
          _recommendCategory,
          for (final c in fetched)
            if (!c.local && c.id.isNotEmpty && c.name != '推荐') c,
        ].take(10).toList(growable: false);
      });
    } catch (_) {}
  }

  Future<CatalogPage> _fetchFeedPage({
    required AppRepository repo,
    required String sourceId,
    required String categoryId,
    required bool more,
    required int page,
    required bool force,
  }) async {
    if (SourceSite.byId(sourceId).recommends) {
      try {
        final rec = await repo.recommendations(
          sourceId,
          categoryId,
          more: more,
          force: force,
        );
        if (rec.items.isNotEmpty || more) return rec;
      } catch (_) {
        if (categoryId.isEmpty && more) rethrow;
      }
    }
    return repo.catalog(
      sourceId,
      page: page,
      category: categoryId,
      force: force,
    );
  }

  Future<void> _loadMoreIfNeeded() async {
    final repo = _repository;
    if (repo == null ||
        _initialLoading ||
        _loadingMore ||
        !_hasMore ||
        _sourceId.isEmpty ||
        _currentIndex < _items.length - 3) {
      return;
    }
    final epoch = _feedEpoch;
    final nextPage = _catalogPage + 1;
    setState(() => _loadingMore = true);
    try {
      final res = await _fetchFeedPage(
        repo: repo,
        sourceId: _sourceId,
        categoryId: _categoryId,
        more: true,
        page: nextPage,
        force: false,
      );
      if (!mounted || epoch != _feedEpoch) return;
      var added = 0;
      for (final item in res.items) {
        if (_seenIds.add(_dramaKey(item))) {
          _items.add(item);
          added++;
        }
      }
      _catalogPage = nextPage;
      _hasMore =
          res.hasMore || (SourceSite.byId(_sourceId).recommends && added > 0);
      setState(() => _loadingMore = false);
    } catch (_) {
      if (mounted && epoch == _feedEpoch) setState(() => _loadingMore = false);
    }
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
      _activeDetailError = null;
    });
    _disposeActiveHandle(save: true);
    _scheduleActivate(index, immediate: false);
    unawaited(_loadMoreIfNeeded());
  }

  void _scheduleActivate(int index, {required bool immediate}) {
    _settleTimer?.cancel();
    if (immediate) {
      unawaited(_activateCard(index));
    } else {
      _settleTimer = Timer(const Duration(milliseconds: 120), () {
        if (mounted && _currentIndex == index) unawaited(_activateCard(index));
      });
    }
  }

  void _disposeActiveHandle({required bool save}) {
    unawaited(_completedSub?.cancel());
    _completedSub = null;
    final handle = _activeHandle;
    final key = _activeKey;
    _activeHandle = null;
    _activeKey = null;
    if (handle == null) return;
    if (save && key != null) {
      _resumeStates[key] = (
        index: handle.session.index,
        position: handle.session.currentPosition,
      );
      unawaited(handle.session.saveProgress(quiet: true));
    }
    handle.dispose();
  }

  Future<DramaDetail> _resolveDetail(Drama drama) {
    final key = _dramaKey(drama);
    final cached = _details.remove(key);
    if (cached != null) {
      _details[key] = cached;
      return Future.value(cached);
    }
    return _detailTasks[key] ??= _fetchDetail(key, drama);
  }

  Future<DramaDetail> _fetchDetail(String key, Drama drama) async {
    try {
      final detail = await _repository!.detail(drama);
      if (_details.length >= _maxDetailCache) {
        _details.remove(_details.keys.first);
      }
      _details[key] = detail;
      return detail;
    } finally {
      _detailTasks.remove(key);
    }
  }

  Future<void> _preloadNext(
    AppRepository repo,
    int fromIndex,
    Drama next,
  ) async {
    try {
      final d = await _resolveDetail(next);
      if (!mounted || _currentIndex != fromIndex || d.episodes.isEmpty) return;
      final nextEp = (_resumeStates[_dramaKey(next)]?.index ?? 0).clamp(
        0,
        d.episodes.length - 1,
      );
      await repo.preload(d.drama, d.episodes[nextEp]);
    } catch (_) {}
  }

  Future<void> _activateCard(int index) async {
    final repo = _repository;
    if (repo == null || index < 0 || index >= _items.length) return;
    final drama = _items[index];
    final key = _dramaKey(drama);
    if (_activeKey == key && _activeHandle != null) {
      _activeHandle!.session.setForeground(_effectiveForeground);
      return;
    }
    final token = ++_activationToken;
    _disposeActiveHandle(save: true);
    setState(() {
      _resolvingDetail = true;
      _activeDetailError = null;
    });

    try {
      final detail = await _resolveDetail(drama);
      if (!mounted || token != _activationToken || _currentIndex != index) {
        return;
      }
      _items[index] = drama.merge(detail.drama);
      if (detail.episodes.isEmpty) {
        setState(() {
          _resolvingDetail = false;
          _activeDetailError = detail.warning.isNotEmpty
              ? detail.warning
              : '暂无可播放剧集';
        });
        return;
      }
      final resume = _resumeStates[key];
      final epIdx = (resume?.index ?? 0).clamp(0, detail.episodes.length - 1);
      final visible = _effectiveForeground;
      final handle = PlaybackHandle(
        repository: repo,
        store: widget.store,
        detail: detail,
        index: epIdx,
        position: resume?.position ?? 0,
        autoplay: visible,
        preopen: true,
      );
      if (_muted) handle.session.setVolume(0);
      handle.session.setForeground(visible);
      _completedSub = handle.session.player.stream.completed.listen((done) {
        if (!done || !mounted || _activeHandle != handle) return;
        Timer(const Duration(milliseconds: 450), () {
          if (!mounted || _activeHandle != handle || !_effectiveForeground) {
            return;
          }
          final s = handle.session;
          if (s.loading || !s.player.state.completed) return;
          if (s.hasNext) {
            unawaited(s.next());
          } else if (index + 1 < _items.length && _pageController.hasClients) {
            unawaited(
              _pageController.nextPage(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
              ),
            );
          }
        });
      });
      setState(() {
        _activeHandle = handle;
        _activeKey = key;
        _resolvingDetail = false;
      });
      if (index + 1 < _items.length) {
        unawaited(_preloadNext(repo, index, _items[index + 1]));
      }
    } catch (e) {
      if (!mounted || token != _activationToken || _currentIndex != index) {
        return;
      }
      setState(() {
        _resolvingDetail = false;
        _activeDetailError = _errorMessage(e);
      });
    }
  }

  Future<void> _openFullPlayer(Drama drama) async {
    final repo = _repository;
    if (repo == null) return;
    final key = _dramaKey(drama);
    final detail = _details[key];
    if (detail == null || detail.episodes.isEmpty) {
      _disposeActiveHandle(save: true);
      await openPage<void>(
        context,
        (_) => DetailPage(store: widget.store, drama: drama, autoplay: true),
      );
      if (mounted) _scheduleActivate(_currentIndex, immediate: true);
      return;
    }
    final cur = _activeKey == key ? _activeHandle?.session : null;
    final epIdx = (cur?.index ?? _resumeStates[key]?.index ?? 0).clamp(
      0,
      detail.episodes.length - 1,
    );
    final pos = cur?.currentPosition ?? _resumeStates[key]?.position ?? 0.0;
    _resumeStates[key] = (index: epIdx, position: pos);
    _disposeActiveHandle(save: false);
    final fullHandle = PlaybackHandle(
      repository: repo,
      store: widget.store,
      detail: detail,
      index: epIdx,
      position: pos,
      autoplay: true,
      preopen: true,
    );
    await openPage<void>(
      context,
      (_) => PlaybackPage(store: widget.store, handle: fullHandle),
    );
    if (mounted) _scheduleActivate(_currentIndex, immediate: true);
  }

  Future<void> _openDramaDetail(Drama drama) async {
    _disposeActiveHandle(save: true);
    await openPage<void>(
      context,
      (_) => DetailPage(store: widget.store, drama: drama),
    );
    if (mounted) _scheduleActivate(_currentIndex, immediate: true);
  }

  Future<void> _showEpisodePicker(Drama drama) async {
    final key = _dramaKey(drama);
    DramaDetail detail;
    try {
      detail = _details[key] ?? await _resolveDetail(drama);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(_errorMessage(e))));
      return;
    }
    if (!mounted || detail.episodes.isEmpty) return;
    final activeIdx = _activeKey == key
        ? (_activeHandle?.session.index ?? 0)
        : (_resumeStates[key]?.index ?? 0);

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF16161A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.6,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${detail.drama.title} · 共 ${detail.episodes.length} 集',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        unawaited(_openFullPlayer(drama));
                      },
                      icon: const Icon(Icons.fullscreen_rounded, size: 18),
                      label: const Text('全屏连播'),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFFFF6B6B),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 68,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: 1.35,
                        ),
                    itemCount: detail.episodes.length,
                    itemBuilder: (_, idx) {
                      final ep = detail.episodes[idx];
                      final selected = idx == activeIdx;
                      return InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          _resumeStates[key] = (index: idx, position: 0);
                          if (_activeKey == key && _activeHandle != null) {
                            unawaited(
                              _activeHandle!.session.play(idx, position: 0),
                            );
                          } else {
                            _scheduleActivate(_currentIndex, immediate: true);
                          }
                        },
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: selected
                                ? const Color(
                                    0xFFFF4D4F,
                                  ).withValues(alpha: 0.22)
                                : Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: selected
                                  ? const Color(0xFFFF4D4F)
                                  : Colors.transparent,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              '${ep.number}',
                              style: TextStyle(
                                color: selected
                                    ? const Color(0xFFFF6B6B)
                                    : Colors.white,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final dy = event.scrollDelta.dy;
    if (dy == 0) return;
    // 换方向先把累积清零，避免来回滚动互相抵消
    if (_wheelAccum != 0 && _wheelAccum.sign != dy.sign) _wheelAccum = 0;
    _wheelAccum += dy;
    if (_wheelAccum.abs() < _wheelStep) return;
    _wheelAccum = 0;
    if (_wheelCooldown != null) return;
    _wheelCooldown = Timer(
      const Duration(milliseconds: 160),
      () => _wheelCooldown = null,
    );
    _turn(dy > 0 ? 1 : -1);
  }

  /// 翻一页。滚轮和方向键共用，动画短一点，手感更跟手。
  void _turn(int direction) {
    if (!_pageController.hasClients) return;
    if (direction > 0) {
      if (_currentIndex + 1 >= _items.length) return;
      unawaited(
        _pageController.nextPage(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        ),
      );
    } else {
      if (_currentIndex <= 0) return;
      unawaited(
        _pageController.previousPage(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  /// 桌面端上下方向键直接翻视频。硬件层先于焦点分发处理，
  /// 这样即使焦点落在按钮、滚动视图上也不会被吃掉。
  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!_isDesktop || !_effectiveForeground || _editingText) return false;
    return _arrowKey(event.logicalKey);
  }

  /// 焦点是否落在输入框里（搜索等），此时方向键要留给光标。
  bool get _editingText {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    var editing = false;
    context.visitAncestorElements((element) {
      if (element.widget is EditableText) {
        editing = true;
        return false;
      }
      return true;
    });
    return editing;
  }

  bool _arrowKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.pageDown) {
      if (_currentIndex + 1 >= _items.length) return false;
      _turn(1);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.pageUp) {
      if (_currentIndex > 0) {
        _turn(-1);
        return true;
      }
      if (widget.onExitUp != null) {
        widget.onExitUp!();
        return true;
      }
    }
    return false;
  }

  KeyEventResult _onKeyEvent(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (_arrowKey(k)) return KeyEventResult.handled;
    if (k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter) {
      _activeHandle?.session.togglePlayback();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  String _errorMessage(Object e) =>
      e is AppFailure && e.message.isNotEmpty ? e.message : e.toString();

  @override
  Widget build(BuildContext context) {
    _syncForeground();
    final site = _sourceId.isNotEmpty ? SourceSite.byId(_sourceId) : null;
    return ColoredBox(
      color: Colors.black,
      child: Focus(
        focusNode: _focusNode,
        autofocus: _isDesktop,
        onKeyEvent: _onKeyEvent,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildBody(),
            if (!AppScope.of(context).television)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.7),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: SafeArea(
                    bottom: false,
                    child: SizedBox(
                      // 桌面端窗口按钮浮在画面顶部，导航条让开这一条
                      height: 50 + _captionInset,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          12 + _railInsetOf(context),
                          _captionInset,
                          12,
                          0,
                        ),
                        child: Row(
                          spacing: 8,
                          children: [
                            if (widget.store.sources.length > 1 && site != null)
                              Builder(
                                builder: (anchor) => ActionChip(
                                  backgroundColor: Colors.black54,
                                  label: Text(
                                    site.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                    ),
                                  ),
                                  onPressed: () =>
                                      pickSource(anchor, widget.store),
                                ),
                              ),
                            Expanded(
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: _categories.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 16),
                                itemBuilder: (_, i) {
                                  final c = _categories[i];
                                  final sel = c.id == _categoryId;
                                  return GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      if (_categoryId == c.id) {
                                        unawaited(refresh());
                                      } else {
                                        setState(() => _categoryId = c.id);
                                        unawaited(_reloadAll(force: false));
                                      }
                                    },
                                    child: Center(
                                      child: Text(
                                        c.name,
                                        style: TextStyle(
                                          color: sel
                                              ? Colors.white
                                              : Colors.white70,
                                          fontSize: sel ? 16 : 15,
                                          fontWeight: sel
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            if (desktopPlatform)
                              IconButton(
                                onPressed: refresh,
                                icon: const Icon(
                                  Icons.refresh_rounded,
                                  color: Colors.white,
                                ),
                              ),
                            if (site != null)
                              IconButton(
                                onPressed: () =>
                                    openSearch(context, widget.store, site),
                                icon: const Icon(
                                  Icons.search_rounded,
                                  color: Colors.white,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_sourceId.isEmpty) {
      return Theme(
        data: ThemeData.dark(useMaterial3: true),
        child: const StatusView(title: '尚未选择片源', message: '请先安装或启用短剧模块'),
      );
    }
    if (_initialLoading) {
      return Theme(
        data: ThemeData.dark(useMaterial3: true),
        child: const StatusView.loading(title: '正在加载推荐短剧'),
      );
    }
    if (_feedError != null && _items.isEmpty) {
      return Theme(
        data: ThemeData.dark(useMaterial3: true),
        child: StatusView(
          title: '推荐流加载失败',
          message: _feedError,
          action: '重试',
          onAction: refresh,
        ),
      );
    }
    if (_items.isEmpty) {
      return Theme(
        data: ThemeData.dark(useMaterial3: true),
        child: StatusView(title: '暂无推荐视频', action: '刷新', onAction: refresh),
      );
    }
    final feed = Listener(
      onPointerSignal: _onPointerSignal,
      child: RefreshIndicator(
        onRefresh: refresh,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: const {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
              PointerDeviceKind.stylus,
            },
          ),
          child: PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            // 桌面端滚轮由 _onPointerSignal 独占，避免和 PageView 自己抢导致要滚好几格
            physics: _isDesktop
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
            onPageChanged: _onPageChanged,
            itemCount: _items.length,
            itemBuilder: (_, index) {
              final drama = _items[index];
              final key = _dramaKey(drama);
              final isCurrent = index == _currentIndex;
              return _FeedSlide(
                key: ValueKey('feed-$key'),
                store: widget.store,
                drama: _details[key]?.drama ?? drama,
                detail: _details[key],
                handle: isCurrent && _activeKey == key ? _activeHandle : null,
                resolving: isCurrent && _resolvingDetail,
                error: isCurrent ? _activeDetailError : null,
                muted: _muted,
                showHeart: isCurrent && _showHeartBurst,
                heartPos: _doubleTapPosition,
                burstKey: _burstKey,
                onRetry: () => _scheduleActivate(index, immediate: true),
                onToggleMute: () {
                  setState(() => _muted = !_muted);
                  _activeHandle?.session.setVolume(_muted ? 0 : 100);
                },
                onDoubleTap: (pos) {
                  setState(() {
                    _doubleTapPosition = pos;
                    _burstKey = UniqueKey();
                    _showHeartBurst = true;
                  });
                  _heartTimer?.cancel();
                  _heartTimer = Timer(const Duration(milliseconds: 700), () {
                    if (mounted) setState(() => _showHeartBurst = false);
                  });
                  unawaited(quickFollow(context, widget.store, drama));
                },
                onEpisodes: () => _showEpisodePicker(drama),
                onFullPlayer: () => _openFullPlayer(drama),
                onDetail: () => _openDramaDetail(drama),
                onPrevious: index > 0 ? () => _turn(-1) : null,
                onNext: index + 1 < _items.length ? () => _turn(1) : null,
              );
            },
          ),
        ),
      ),
    );
    // 刷新推荐时只在顶部给一条细进度条，画面保持不动
    return Stack(
      children: [
        Positioned.fill(child: feed),
        if (_refreshing)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}

class _FeedSlide extends StatefulWidget {
  const _FeedSlide({
    super.key,
    required this.store,
    required this.drama,
    required this.detail,
    required this.handle,
    required this.resolving,
    required this.error,
    required this.muted,
    required this.showHeart,
    required this.heartPos,
    required this.burstKey,
    required this.onRetry,
    required this.onToggleMute,
    required this.onDoubleTap,
    required this.onEpisodes,
    required this.onFullPlayer,
    required this.onDetail,
    this.onPrevious,
    this.onNext,
  });

  final LocalStore store;
  final Drama drama;
  final DramaDetail? detail;
  final PlaybackHandle? handle;
  final bool resolving;
  final String? error;
  final bool muted;
  final bool showHeart;
  final Offset? heartPos;
  final Key burstKey;
  final VoidCallback onRetry;
  final VoidCallback onToggleMute;
  final ValueChanged<Offset> onDoubleTap;
  final VoidCallback onEpisodes;
  final VoidCallback onFullPlayer;
  final VoidCallback onDetail;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  State<_FeedSlide> createState() => _FeedSlideState();
}

class _FeedSlideState extends State<_FeedSlide> {
  bool _expanded = false;
  Offset _tapDown = Offset.zero;

  static bool get _desktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  Widget build(BuildContext context) {
    final session = widget.handle?.session;
    if (session == null) return _content(context, null);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => _content(context, session),
    );
  }

  static String _speedText(double value) {
    final text = value.toStringAsFixed(2);
    return text.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }

  Future<void> _pickSpeed(PlaybackSession session) async {
    final picked = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: const Color(0xFF16161A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '播放速度',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final speed in playbackSpeeds)
                    ChoiceChip(
                      label: Text('${_speedText(speed)}x'),
                      selected: (session.speed - speed).abs() < .001,
                      onSelected: (_) => Navigator.pop(ctx, speed),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) await session.setSpeed(picked);
  }

  Widget _content(BuildContext context, PlaybackSession? session) {
    final ready = session != null && session.ready;
    final err = widget.error ?? session?.error;
    final total = widget.detail?.episodes.length ?? widget.drama.episodes;
    final epNum = session?.episode.number ?? 1;

    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: ready ? 0 : 1,
            duration: const Duration(milliseconds: 220),
            child: DramaCover(drama: widget.drama, radius: 0, details: false),
          ),
        ),
        if (widget.handle != null && session != null)
          Center(
            child: PlayerVideo(handle: widget.handle!, player: session.player),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 270,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.84),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => session?.togglePlayback(),
            onDoubleTapDown: (d) => _tapDown = d.localPosition,
            onDoubleTap: () => widget.onDoubleTap(_tapDown),
            onLongPressStart: (_) => session?.beginBoost(),
            onLongPressEnd: (_) => session?.endBoost(),
            onLongPressCancel: () => session?.endBoost(),
          ),
        ),
        if (session != null &&
            ready &&
            err == null &&
            !session.player.state.playing)
          const Center(
            child: IgnorePointer(
              child: Icon(
                Icons.play_arrow_rounded,
                size: 64,
                color: Colors.white70,
              ),
            ),
          ),
        if (session != null && session.boosting)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 58,
            left: 0,
            right: 0,
            child: const Center(
              child: Chip(
                backgroundColor: Colors.black87,
                label: Text(
                  '2.0x 快进播放中',
                  style: TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ),
        if (widget.showHeart && widget.heartPos != null)
          Positioned(
            left: widget.heartPos!.dx - 40,
            top: widget.heartPos!.dy - 40,
            child: IgnorePointer(
              child: Icon(
                Icons.favorite_rounded,
                key: widget.burstKey,
                color: const Color(0xFFFF3B5C),
                size: 80,
              ),
            ),
          ),
        if (err != null)
          Center(
            child: FilledButton.tonal(
              onPressed: session != null
                  ? () => unawaited(session.retry())
                  : widget.onRetry,
              child: Text('重试：$err', maxLines: 1),
            ),
          ),
        // 右侧功能栏：整体上移，给底部条腾位置；窗口矮时等比缩小
        Positioned(
          right: 10,
          width: 76,
          top: 64 + _captionInset + MediaQuery.paddingOf(context).top,
          bottom: 124,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.bottomCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 14,
              children: [
                Column(
                  children: [
                    FollowIcon(
                      store: widget.store,
                      drama: widget.drama,
                      color: Colors.white,
                      activeColor: const Color(0xFFFF3B5C),
                      size: 28,
                      extent: 44,
                    ),
                    const Text(
                      '追剧',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        shadows: _RailBtn._shadow,
                      ),
                    ),
                  ],
                ),
                _RailBtn(
                  icon: Icons.format_list_numbered_rounded,
                  label: total > 0 ? '选集·$total' : '选集',
                  onTap: widget.onEpisodes,
                ),
                _RailBtn(
                  icon: Icons.speed_rounded,
                  label: session == null
                      ? '倍速'
                      : '${_speedText(session.speed)}x',
                  onTap: session == null
                      ? null
                      : () => unawaited(_pickSpeed(session)),
                ),
                _RailBtn(
                  icon: Icons.fullscreen_rounded,
                  label: '全屏',
                  onTap: widget.onFullPlayer,
                ),
                _RailBtn(
                  icon: widget.muted
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                  label: widget.muted ? '静音' : '声音',
                  onTap: widget.onToggleMute,
                ),
                // 桌面端没有触摸：上下翻页按钮和上面几个长得一样
                if (_desktop)
                  _RailBtn(
                    icon: Icons.keyboard_arrow_up_rounded,
                    label: '上一个',
                    onTap: widget.onPrevious,
                  ),
                if (_desktop)
                  _RailBtn(
                    icon: Icons.keyboard_arrow_down_rounded,
                    label: '下一个',
                    onTap: widget.onNext,
                  ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 14 + _railInsetOf(context),
          right: 14,
          bottom: 16,
          child: ConstrainedBox(
            // 宽屏不要把整条拉满，手机上自动占满可用宽度
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                GestureDetector(
                  onTap: widget.onDetail,
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [
                      Text(
                        widget.drama.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '第$epNum集',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                      if (widget.drama.vip) const VipBadge(),
                    ],
                  ),
                ),
                if (widget.drama.description.trim().isNotEmpty)
                  GestureDetector(
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Text(
                      widget.drama.description.trim(),
                      maxLines: _expanded ? 5 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                  ),
                Material(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: widget.onFullPlayer,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.play_circle_fill_rounded,
                            color: Color(0xFFFF4D4F),
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              total > 0
                                  ? '观看完整短剧 · 共 $total 集'
                                  : '观看完整短剧 · 选集连播',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: Colors.white70,
                            size: 18,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _ProgressBar(
            player: session?.player,
            session: session,
            loading: widget.resolving || (session?.loading ?? true),
          ),
        ),
      ],
    );
  }
}

class _RailBtn extends StatelessWidget {
  const _RailBtn({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// 亮画面上的白字需要一点阴影才看得清。
  static const _shadow = [Shadow(color: Color(0x8C000000), blurRadius: 4)];

  @override
  Widget build(BuildContext context) {
    final color = onTap == null
        ? Colors.white.withValues(alpha: .45)
        : Colors.white;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 2,
        children: [
          Icon(icon, color: color, size: 28, shadows: _shadow),
          Text(
            label,
            style: TextStyle(color: color, fontSize: 11.5, shadows: _shadow),
          ),
        ],
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.player,
    required this.session,
    required this.loading,
  });
  final Player? player;
  final PlaybackSession? session;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    if (player == null || loading) {
      return const LinearProgressIndicator(
        minHeight: 2,
        backgroundColor: Colors.white12,
        valueColor: AlwaysStoppedAnimation(Color(0xFFFF4D4F)),
      );
    }
    return StreamBuilder<Duration>(
      stream: player!.stream.position,
      initialData: player!.state.position,
      builder: (context, snap) {
        final total = player!.state.duration.inMilliseconds;
        if (total <= 0) return const SizedBox(height: 2);
        final ratio = ((snap.data?.inMilliseconds ?? 0) / total).clamp(
          0.0,
          1.0,
        );
        return LayoutBuilder(
          builder: (_, box) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              final ms =
                  (total * (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0))
                      .round();
              unawaited(session?.seekTo(Duration(milliseconds: ms)));
            },
            child: SizedBox(
              height: 10,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: LinearProgressIndicator(
                  minHeight: 2.5,
                  value: ratio,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation(Colors.white),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
