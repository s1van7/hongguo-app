package core

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"testing"
)

// recTestProvider 用一个自增的页码模拟站源：每次调用返回 3 部新剧，
// 翻到底后 hasMore 变成 false。
type recTestProvider struct {
	calls  int
	offset int
	limit  int
}

func (p *recTestProvider) Descriptor() SourceDescriptor {
	return SourceDescriptor{ID: "rectest"}
}
func (p *recTestProvider) Categories(context.Context, bool) ([]Category, error) { return nil, nil }
func (p *recTestProvider) CatalogPage(context.Context, int, string) ([]Drama, bool, error) {
	return nil, false, nil
}
func (p *recTestProvider) Detail(context.Context, string) (Drama, []Chapter, error) {
	return Drama{}, nil, nil
}
func (p *recTestProvider) ResolveMedia(context.Context, Task) (ProviderMedia, error) {
	return ProviderMedia{}, nil
}
func (p *recTestProvider) Search(context.Context, int, string) ([]Drama, bool, error) {
	return nil, false, nil
}
func (p *recTestProvider) Suggestions(context.Context, string) ([]string, error) {
	return nil, nil
}
func (p *recTestProvider) ProvidesCapability(capability reflect.Type) bool {
	return capability == reflect.TypeFor[Recommender]()
}
func (p *recTestProvider) ValidRecommendation(genre string, cursor json.RawMessage) error {
	return nil
}

func (p *recTestProvider) Recommendations(_ context.Context, _ string, cursor json.RawMessage, seen []string) (RecommendationPage, error) {
	p.calls++
	offset := 0
	if len(cursor) > 0 {
		var state struct {
			Offset int `json:"offset"`
		}
		if err := json.Unmarshal(cursor, &state); err != nil {
			return RecommendationPage{}, err
		}
		offset = state.Offset
	}
	skip := make(map[string]bool, len(seen))
	for _, id := range seen {
		skip[id] = true
	}
	dramas := make([]Drama, 0, 3)
	for i := offset; i < offset+3 && i < p.limit; i++ {
		id := fmt.Sprintf("rectest:%d", i)
		if skip[id] {
			continue
		}
		dramas = append(dramas, Drama{ID: id, Name: id, Source: "rectest"})
	}
	next, _ := json.Marshal(map[string]int{"offset": offset + 3})
	return RecommendationPage{Dramas: dramas, Cursor: next, HasMore: offset+3 < p.limit}, nil
}

func newRecTestEngine(t *testing.T) (*nativeEngine, *recTestProvider) {
	t.Helper()
	provider := &recTestProvider{limit: 9}
	descriptor := SourceDescriptor{ID: "rectest"}
	Register(descriptor, func(Host) Provider { return provider })
	t.Cleanup(func() { Unregister("rectest") })
	dir := t.TempDir()
	engine, err := newNativeEngine(dir+"/data", dir+"/cache", dir+"/downloads")
	if err != nil {
		t.Fatal(err)
	}
	return engine, provider
}

func recTestInput(force bool) nativeInput {
	return nativeInput{Action: "recommendations", Source: "rectest", Category: "", Force: force}
}

func recTestIDs(result nativeCatalogResult) []string {
	ids := make([]string, 0, len(result.Items))
	for _, drama := range result.Items {
		ids = append(ids, drama.ID)
	}
	return ids
}

// 每次「刷新推荐」都要拿到上一轮没出现过的新剧，而不是把首页原样再来一遍。
func TestNativeRecommendationsForceRefreshReturnsNewItems(t *testing.T) {
	engine, provider := newRecTestEngine(t)
	ctx := context.Background()

	first, err := engine.nativeRecommendations(ctx, recTestInput(false))
	if err != nil {
		t.Fatal(err)
	}
	if got := len(first.Items); got != 3 {
		t.Fatalf("首屏数量 = %d, 期望 3", got)
	}
	seen := map[string]bool{}
	for _, id := range recTestIDs(first) {
		seen[id] = true
	}

	for round := 0; round < 2; round++ {
		next, err := engine.nativeRecommendations(ctx, recTestInput(true))
		if err != nil {
			t.Fatalf("第 %d 次刷新失败：%v", round+1, err)
		}
		if len(next.Items) == 0 {
			t.Fatalf("第 %d 次刷新没有返回任何剧集", round+1)
		}
		for _, id := range recTestIDs(next) {
			if seen[id] {
				t.Fatalf("第 %d 次刷新出现了重复剧集 %s", round+1, id)
			}
			seen[id] = true
		}
	}
	if provider.calls < 3 {
		t.Fatalf("刷新时没有重新请求站源，调用次数 = %d", provider.calls)
	}
}

// 站源翻到头之后刷新要能从头开始，不能直接报错或给出空列表。
func TestNativeRecommendationsForceRefreshWrapsAround(t *testing.T) {
	engine, _ := newRecTestEngine(t)
	ctx := context.Background()

	if _, err := engine.nativeRecommendations(ctx, recTestInput(false)); err != nil {
		t.Fatal(err)
	}
	for round := 0; round < 5; round++ {
		result, err := engine.nativeRecommendations(ctx, recTestInput(true))
		if err != nil {
			t.Fatalf("第 %d 次刷新失败：%v", round+1, err)
		}
		if len(result.Items) == 0 {
			t.Fatalf("第 %d 次刷新返回空列表", round+1)
		}
	}
}

// 已看列表只保留最近 540 条，避免过滤条件无限增长。
func TestNativeMergeSeenCapsHistory(t *testing.T) {
	seen := make([]string, 0, 600)
	for i := 0; i < 600; i++ {
		seen = append(seen, fmt.Sprintf("rectest:%d", i))
	}
	merged := nativeMergeSeen(seen, []LibraryDrama{{ID: "rectest:600"}})
	if len(merged) != 540 {
		t.Fatalf("长度 = %d, 期望 540", len(merged))
	}
	if merged[len(merged)-1] != "rectest:600" {
		t.Fatalf("末尾 = %s, 期望最新一条", merged[len(merged)-1])
	}
}
