package core

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"sync"

	"github.com/metacubex/mihomo/component/age"
	"github.com/metacubex/mihomo/config"
	"go.yaml.in/yaml/v3"
)

// One entry holds the whole parsed profile: the host reads base sections,
// outbounds and the merged document from the same file while it edits. Parsing
// it is the most expensive thing a large subscription costs, so the exact wire
// bytes are the key and the raw config, short-id classification and response
// digest are cached with that parse.
const maxCachedProfileSize = 4 << 20

type profileSnapshot struct {
	digest   string
	document *yaml.Node
	raw      *config.RawConfig
	retag    bool
}

var profileCache struct {
	mu       sync.RWMutex
	buf      []byte
	digest   string
	document *yaml.Node
	raw      *config.RawConfig
	retag    bool
}

// parseProfileSnapshot decrypts wire bytes into the document and raw config
// that profile readers share.
func parseProfileSnapshot(wire []byte) (*profileSnapshot, error) {
	buf, err := age.DecryptBytes(wire)
	if err != nil {
		return nil, fmt.Errorf("decrypt config error: %w", err)
	}
	document, err := parseProfileDocument(buf)
	if err != nil {
		return nil, err
	}
	retag := bytes.Contains(buf, []byte("short-id"))
	if retag {
		retagShortIDs(document)
	}
	raw := config.DefaultRawConfig()
	if err := document.Decode(raw); err != nil {
		return nil, err
	}
	return &profileSnapshot{
		digest:   hex.EncodeToString(sha256Sum(wire)),
		document: document,
		raw:      raw,
		retag:    retag,
	}, nil
}

// readProfile decrypts and parses [path] once, reusing the whole snapshot when
// the file bytes are unchanged. Byte comparison avoids hashing every repeated
// read and cannot answer an unchanged profile after a digest collision.
func readProfile(path string) (*profileSnapshot, error) {
	wire, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	profileCache.mu.RLock()
	cachedBuf := profileCache.buf
	snapshot := &profileSnapshot{
		digest:   profileCache.digest,
		document: profileCache.document,
		raw:      profileCache.raw,
		retag:    profileCache.retag,
	}
	hit := snapshot.raw != nil && snapshot.document != nil && bytes.Equal(wire, cachedBuf)
	profileCache.mu.RUnlock()
	if hit {
		return snapshot, nil
	}

	snapshot, err = parseProfileSnapshot(wire)
	if err != nil {
		return nil, err
	}
	if len(wire) > maxCachedProfileSize {
		return snapshot, nil
	}

	profileCache.mu.Lock()
	profileCache.buf = append([]byte(nil), wire...)
	profileCache.digest = snapshot.digest
	profileCache.document = snapshot.document
	profileCache.raw = snapshot.raw
	profileCache.retag = snapshot.retag
	profileCache.mu.Unlock()
	return snapshot, nil
}

func sha256Sum(buf []byte) []byte {
	sum := sha256.Sum256(buf)
	return sum[:]
}

func parseProfileDocument(buf []byte) (*yaml.Node, error) {
	var document yaml.Node
	if err := yaml.Unmarshal(buf, &document); err != nil {
		return nil, err
	}
	return &document, nil
}

// forgetProfile drops the cached snapshot: a config the host wrote makes the
// parse of what stood there before it stale.
func forgetProfileRaw() {
	profileCache.mu.Lock()
	profileCache.buf = nil
	profileCache.digest = ""
	profileCache.document = nil
	profileCache.raw = nil
	profileCache.retag = false
	profileCache.mu.Unlock()
}
