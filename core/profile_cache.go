package core

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"sync"

	"github.com/metacubex/mihomo/config"
	"go.yaml.in/yaml/v3"
)

// One entry holds the last profile document: the host merges the same profile
// twice per edit, once to build it and once to apply it, and a merge is almost
// entirely the parse of that document.
//
// The merge only reads the document. What later reaches into it, the writer's
// alias inlining and the short-id retagging, is idempotent, so a document the
// writer has already been through merges the same way the second time.
// TestMergeProfileBaseProducesTheSameDocumentTwice holds that to be true.
const maxCachedProfileDocumentSize = 4 << 20

var profileDocumentCache struct {
	mu       sync.RWMutex
	digest   string
	document *yaml.Node
}

// One entry holds the last profile read: the host opens a profile, previews it
// and applies it, and each of those re-reads the same file. Parsing it is the
// most expensive thing a large subscription costs, so the digest the host
// already computes is the key.
const maxCachedProfileSize = 4 << 20

var profileRawCache struct {
	mu     sync.RWMutex
	digest string
	raw    *config.RawConfig
}

// readRawConfig parses [path], reusing the parse when the file is unchanged.
func readRawConfig(path string) (*config.RawConfig, []byte, error) {
	buf, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, err
	}
	if len(buf) > maxCachedProfileSize {
		raw, err := unmarshalRawConfig(buf)
		return raw, buf, err
	}
	digest := hex.EncodeToString(sha256Sum(buf))

	profileRawCache.mu.RLock()
	cached := profileRawCache.raw
	hit := digest == profileRawCache.digest && cached != nil
	profileRawCache.mu.RUnlock()
	if hit {
		return cached, buf, nil
	}

	raw, err := unmarshalRawConfig(buf)
	if err != nil {
		return nil, buf, err
	}
	profileRawCache.mu.Lock()
	profileRawCache.digest = digest
	profileRawCache.raw = raw
	profileRawCache.mu.Unlock()
	return raw, buf, nil
}

func sha256Sum(buf []byte) []byte {
	sum := sha256.Sum256(buf)
	return sum[:]
}

// readProfileDocument parses the profile document, reusing the parse when the
// file is unchanged.
func readProfileDocument(buf []byte) (*yaml.Node, error) {
	if len(buf) > maxCachedProfileDocumentSize {
		return parseProfileDocument(buf)
	}
	digest := hex.EncodeToString(sha256Sum(buf))

	profileDocumentCache.mu.RLock()
	cached := profileDocumentCache.document
	hit := digest == profileDocumentCache.digest && cached != nil
	profileDocumentCache.mu.RUnlock()
	if hit {
		return cached, nil
	}

	document, err := parseProfileDocument(buf)
	if err != nil {
		return nil, err
	}
	profileDocumentCache.mu.Lock()
	profileDocumentCache.digest = digest
	profileDocumentCache.document = document
	profileDocumentCache.mu.Unlock()
	return document, nil
}

func parseProfileDocument(buf []byte) (*yaml.Node, error) {
	var document yaml.Node
	if err := yaml.Unmarshal(buf, &document); err != nil {
		return nil, err
	}
	return &document, nil
}

// forgetProfileRaw drops the cached parse: a config the host wrote makes the
// parse of what stood there before it stale.
func forgetProfileRaw() {
	profileRawCache.mu.Lock()
	profileRawCache.digest = ""
	profileRawCache.raw = nil
	profileRawCache.mu.Unlock()
}
