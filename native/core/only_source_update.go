package core

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
)

var onlySourceUpdateBase = ""

const (
	onlySourceManifestBytes = 64 << 10
	onlySourceCodeBytes     = 4 << 20
)

type nativeSourceUpdate struct {
	Updated bool   `json:"updated"`
	Version string `json:"version"`
	Current string `json:"current"`
}

func onlySourceUpdateBases() []string {
	bases := []string{}
	for _, base := range strings.Split(onlySourceUpdateBase, ",") {
		if base = strings.TrimRight(strings.TrimSpace(base), "/"); base != "" {
			bases = append(bases, base)
		}
	}
	return bases
}

func (engine *nativeEngine) currentOnlySourceVersion() string {
	module, err := readModule(filepath.Join(engine.downloader.moduleRoot(), onlySourceID))
	if err != nil {
		return ""
	}
	return module.manifest.Version
}

func (engine *nativeEngine) updateOnlySource(ctx context.Context) (nativeSourceUpdate, error) {
	bases := onlySourceUpdateBases()
	if len(bases) == 0 {
		return nativeSourceUpdate{}, errors.New("这个安装包没有配置红果源更新地址")
	}
	current := engine.currentOnlySourceVersion()
	var last error
	for _, base := range bases {
		result, err := engine.fetchOnlySourceUpdate(ctx, base, current)
		if err == nil {
			return result, nil
		}
		last = err
	}
	return nativeSourceUpdate{}, last
}

func (engine *nativeEngine) fetchOnlySourceUpdate(ctx context.Context, base, current string) (nativeSourceUpdate, error) {
	raw, err := engine.fetchModuleResource(ctx, base+"/"+moduleManifest, onlySourceManifestBytes)
	if err != nil {
		return nativeSourceUpdate{}, err
	}
	var manifest ModuleManifest
	if err = json.Unmarshal(raw, &manifest); err != nil {
		return nativeSourceUpdate{}, errors.New("红果源清单格式无效")
	}
	if manifest.ID != onlySourceID {
		return nativeSourceUpdate{}, errors.New("更新包不是红果源")
	}
	result := nativeSourceUpdate{Version: manifest.Version, Current: current}
	if !newerModuleVersion(manifest.Version, current) {
		return result, nil
	}
	code, err := engine.fetchModuleResource(ctx, base+"/"+moduleEntry, onlySourceCodeBytes)
	if err != nil {
		return nativeSourceUpdate{}, err
	}
	if _, err = parseModule(raw, code); err != nil {
		return nativeSourceUpdate{}, err
	}
	if err = engine.downloader.writeModuleLocked(onlySourceID, raw, code); err != nil {
		return nativeSourceUpdate{}, err
	}
	engine.downloader.loadModules()
	result.Updated = true
	result.Current = manifest.Version
	return result, nil
}
