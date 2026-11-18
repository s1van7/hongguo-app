package core

import (
	"context"
	"encoding/json"
	"errors"
	"time"
)

type nativeRecommendationState struct {
	Query   json.RawMessage `json:"query"`
	Seen    []string        `json:"seen,omitempty"`
	Page    int             `json:"page"`
	HasMore bool            `json:"hasMore"`
}

func nativeRecommendationKey(source, genre string) string {
	return source + "|recommendation:" + genre
}

// nativeFreshRecommendations 把站源返回的一页数据里没出现过的剧集挑出来。
func nativeFreshRecommendations(dramas []Drama, known map[string]LibraryDrama, seen map[string]bool) []LibraryDrama {
	fresh := make([]LibraryDrama, 0, len(dramas))
	for _, drama := range dramas {
		item := NativeNormalize(drama)
		if old, exists := known[item.ID]; exists {
			item = MergeNativeDrama(old, item)
		}
		if seen[item.ID] {
			continue
		}
		seen[item.ID] = true
		fresh = append(fresh, item)
	}
	return fresh
}

// nativeMergeSeen 把新出现的剧集并入已看列表，只保留最近 540 条，
// 避免过滤条件无限增长。
func nativeMergeSeen(seen []string, fresh []LibraryDrama) []string {
	merged := make([]string, 0, len(seen)+len(fresh))
	added := make(map[string]bool, len(seen)+len(fresh))
	for _, id := range seen {
		if id == "" || added[id] {
			continue
		}
		added[id] = true
		merged = append(merged, id)
	}
	for _, drama := range fresh {
		if drama.ID == "" || added[drama.ID] {
			continue
		}
		added[drama.ID] = true
		merged = append(merged, drama.ID)
	}
	if len(merged) > 540 {
		merged = merged[len(merged)-540:]
	}
	return merged
}

func (engine *nativeEngine) recommender(source string) (Recommender, error) {
	if engine.downloader != nil {
		if p, ok := engine.downloader.provider(source); ok {
			if recommender, ok := providerAs[Recommender](p); ok {
				return recommender, nil
			}
		}
	}
	return nil, errors.New("请选择有效站源")
}

func (engine *nativeEngine) cachedRecommendations(source, genre string) (nativeCatalogResult, error) {
	recommender, err := engine.recommender(source)
	if err != nil {
		return nativeCatalogResult{}, err
	}
	if err := recommender.ValidRecommendation(genre, nil); err != nil {
		return nativeCatalogResult{}, err
	}
	key := nativeRecommendationKey(source, genre)
	result := engine.nativeCached(key)
	engine.mu.Lock()
	_, found := engine.recommendations[key]
	engine.mu.Unlock()
	if !found && len(result.Items) > 0 {
		result.Fresh, result.HasMore = false, false
		result.Warning = joinNativeWarnings(result.Warning, "推荐位置已失效，请刷新推荐")
	}
	return result, nil
}

func (engine *nativeEngine) nativeRecommendations(ctx context.Context, input nativeInput) (nativeCatalogResult, error) {
	source, genre := nativeActionSource(input), input.Category
	recommender, err := engine.recommender(source)
	if err != nil {
		return nativeCatalogResult{}, err
	}
	if err := recommender.ValidRecommendation(genre, nil); err != nil {
		return nativeCatalogResult{}, err
	}
	key := nativeRecommendationKey(source, genre)
	unlock, err := engine.lockSourceCatalog(ctx, source)
	if err != nil {
		return nativeCatalogResult{}, err
	}
	defer unlock()
	if retried, err := engine.retryCatalogSave(); retried {
		cached, _ := engine.cachedRecommendations(source, genre)
		if err != nil || len(cached.Items) > 0 {
			return cached, nil
		}
	}
	cached, _ := engine.cachedRecommendations(source, genre)
	engine.mu.Lock()
	state, found := engine.recommendations[key]
	engine.mu.Unlock()
	if !input.Force && found && len(cached.Items) > 0 && (input.Command != "more" || !state.HasMore) {
		return cached, nil
	}
	if !input.Force && !found && len(cached.Items) > 0 {
		return cached, nil
	}
	// 刷新推荐时不清空浏览位置：接着上次的游标往后取，并把已经展示过的剧集
	// 当作过滤条件传给站源，保证每次刷新都是没看过的新内容；只有站源翻到
	// 底了（HasMore 为 false）才从头开始新一轮。
	if input.Force {
		if found && state.HasMore {
			state = nativeRecommendationState{
				Query:   state.Query,
				Seen:    state.Seen,
				Page:    state.Page,
				HasMore: true,
			}
		} else {
			state = nativeRecommendationState{HasMore: true}
		}
	} else if !found {
		state = nativeRecommendationState{HasMore: true}
	}
	engine.mu.Lock()
	known := make(map[string]LibraryDrama, len(engine.catalogs[source]))
	for _, drama := range engine.catalogs[source] {
		known[drama.ID] = drama
	}
	engine.mu.Unlock()
	var page RecommendationPage
	var fresh []LibraryDrama
	for attempt := 0; ; attempt++ {
		seen := make(map[string]bool, len(state.Seen))
		for _, id := range state.Seen {
			seen[id] = true
		}
		page, err = recommender.Recommendations(ctx, genre, state.Query, state.Seen)
		if err != nil {
			if len(cached.Items) == 0 || errors.Is(err, context.Canceled) {
				return nativeCatalogResult{}, err
			}
			cached.Fresh = false
			cached.Warning = joinNativeWarnings(cached.Warning, PublicError(err).Error())
			return cached, nil
		}
		if err := ctx.Err(); err != nil {
			return nativeCatalogResult{}, err
		}
		fresh = nativeFreshRecommendations(page.Dramas, known, seen)
		if len(fresh) > 0 || attempt > 0 || !input.Force {
			break
		}
		// 刷新时站源已经没有更多新内容：清空已看记录，从头开始新一轮。
		state = nativeRecommendationState{HasMore: true}
	}
	if len(fresh) == 0 && page.HasMore {
		return nativeCatalogResult{}, errors.New("暂时没有新的推荐，已保留上次位置；可重试或刷新推荐")
	}
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.recommendations == nil {
		engine.recommendations = map[string]nativeRecommendationState{}
	}
	previous := engine.catalogs[key]
	if input.Force {
		previous = nil
	}
	items := mergeNativeCatalog(previous, fresh)
	state.Query, state.Seen = page.Cursor, nativeMergeSeen(state.Seen, fresh)
	state.Page++
	state.HasMore = page.HasMore
	engine.recommendations[key] = state
	engine.catalogs[key] = items
	engine.catalogs[source] = mergeNativeCatalog(engine.catalogs[source], fresh)
	engine.commitProviderStateLocked(source)
	engine.catalogStates[key] = nativeCatalogState{UpdatedAt: time.Now(), Page: state.Page, HasMore: state.HasMore}
	result := nativeCatalogResult{Items: append([]LibraryDrama{}, items...), Page: state.Page, HasMore: state.HasMore, Fresh: true}
	if err := engine.writeCatalogDiskLocked(); err != nil {
		result.Fresh, result.Warning, result.saveError = false, err.Error(), err
	}
	return result, nil
}
