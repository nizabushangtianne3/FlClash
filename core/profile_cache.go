package core

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"sync"

	"github.com/metacubex/mihomo/config"
)

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
	out := make([]byte, len(sum))
	copy(out, sum[:])
	return out
}

// forgetProfileRaw drops the cached parse: a config the host wrote makes the
// parse of what stood there before it stale.
func forgetProfileRaw() {
	profileRawCache.mu.Lock()
	profileRawCache.digest = ""
	profileRawCache.raw = nil
	profileRawCache.mu.Unlock()
}
