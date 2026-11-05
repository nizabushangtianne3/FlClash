package core

import (
	"bytes"
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
	buf      []byte
	document *yaml.Node
	retag    bool
}

// One entry holds the last profile read: the host opens a profile, previews it
// and applies it, and each of those re-reads the same file. Parsing it is the
// most expensive thing a large subscription costs, so the exact bytes are the
// key and the response digest is cached with the parse.
const maxCachedProfileSize = 4 << 20

var profileRawCache struct {
	mu     sync.RWMutex
	buf    []byte
	digest string
	raw    *config.RawConfig
}

// readRawConfig parses [path], reusing the parse and digest when the file is
// unchanged. Comparing bytes avoids hashing every repeated read and prevents
// an unchanged profile from being answered after a digest collision.
func readCachedRawConfig(path string) (*config.RawConfig, string, error) {
	buf, err := os.ReadFile(path)
	if err != nil {
		return nil, "", err
	}
	if len(buf) > maxCachedProfileSize {
		raw, err := unmarshalRawConfig(buf)
		if err != nil {
			return nil, "", err
		}
		return raw, hex.EncodeToString(sha256Sum(buf)), nil
	}

	profileRawCache.mu.RLock()
	cachedBuf := profileRawCache.buf
	cached := profileRawCache.raw
	cachedDigest := profileRawCache.digest
	hit := cached != nil && bytes.Equal(buf, cachedBuf)
	profileRawCache.mu.RUnlock()
	if hit {
		return cached, cachedDigest, nil
	}

	raw, err := unmarshalRawConfig(buf)
	if err != nil {
		return nil, "", err
	}
	digest := hex.EncodeToString(sha256Sum(buf))
	profileRawCache.mu.Lock()
	profileRawCache.buf = append([]byte(nil), buf...)
	profileRawCache.digest = digest
	profileRawCache.raw = raw
	profileRawCache.mu.Unlock()
	return raw, digest, nil
}

func sha256Sum(buf []byte) []byte {
	sum := sha256.Sum256(buf)
	return sum[:]
}

// readProfileDocument parses the profile document and reports whether its wire
// bytes contain short-id. Reusing the parse and classification avoids hashing
// and scanning an unchanged profile on every repeated merge.
func readProfileDocument(buf []byte) (*yaml.Node, bool, error) {
	if len(buf) > maxCachedProfileDocumentSize {
		document, err := parseProfileDocument(buf)
		if err != nil {
			return nil, false, err
		}
		return document, bytes.Contains(buf, []byte("short-id")), nil
	}

	profileDocumentCache.mu.RLock()
	cachedBuf := profileDocumentCache.buf
	cached := profileDocumentCache.document
	hit := cached != nil && bytes.Equal(buf, cachedBuf)
	cachedRetag := profileDocumentCache.retag
	profileDocumentCache.mu.RUnlock()
	if hit {
		return cached, cachedRetag, nil
	}

	document, err := parseProfileDocument(buf)
	if err != nil {
		return nil, false, err
	}
	retag := bytes.Contains(buf, []byte("short-id"))
	profileDocumentCache.mu.Lock()
	profileDocumentCache.buf = append([]byte(nil), buf...)
	profileDocumentCache.document = document
	profileDocumentCache.retag = retag
	profileDocumentCache.mu.Unlock()
	return document, retag, nil
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
	profileRawCache.buf = nil
	profileRawCache.digest = ""
	profileRawCache.raw = nil
	profileRawCache.mu.Unlock()
}
