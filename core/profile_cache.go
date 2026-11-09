package core

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"slices"
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

// A snapshot is immutable once parsed; the cache publishes a complete pointer,
// so readers that take the pointer before a refresh keep a coherent old view.
type profileSnapshot struct {
	digest   string
	document *yaml.Node
	raw      *config.RawConfig
	retag    bool
}

var profileCache struct {
	mu       sync.RWMutex
	buf      []byte
	snapshot *profileSnapshot
}

// A read that only compares against the cached bytes does not need to own
// them, so it borrows a buffer from the pool: the host re-reads the base every
// time it opens a section, and a fresh buffer each time is pure garbage.
var profileCompareBuffers = sync.Pool{New: func() any {
	buffer := make([]byte, 0, 64<<10)
	return &buffer
}}

// profileBytes reads path into a borrowed buffer: it hands the bytes back when
// they match the cached ones, and gives the caller ownership when they do not,
// so a changed profile is parsed from the read instead of read again.
func profileBytes(path string, cached []byte) ([]byte, bool, error) {
	pooled := profileCompareBuffers.Get().(*[]byte)
	read, err := readFileInto(*pooled, path)
	*pooled = read
	if err != nil {
		profileCompareBuffers.Put(pooled)
		return nil, false, err
	}
	if bytes.Equal(read, cached) {
		profileCompareBuffers.Put(pooled)
		return nil, true, nil
	}
	return read, false, nil
}

// readFileInto fills dst with the whole file, growing it only when the file
// outgrows the capacity it brought.
func readFileInto(dst []byte, path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return dst, err
	}
	defer file.Close()
	if info, err := file.Stat(); err == nil {
		if grow := info.Size() + 1 - int64(cap(dst)); grow > 0 {
			dst = slices.Grow(dst[:0], int(grow))
		}
	}
	dst = dst[:0]
	for {
		if len(dst) == cap(dst) {
			dst = slices.Grow(dst, 1<<16)
		}
		read, err := file.Read(dst[len(dst):cap(dst)])
		dst = dst[:len(dst)+read]
		if err == io.EOF {
			return dst, nil
		}
		if err != nil {
			return dst, err
		}
	}
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
	profileCache.mu.RLock()
	cachedBuf, cached := profileCache.buf, profileCache.snapshot
	profileCache.mu.RUnlock()

	var wire []byte
	if cached == nil {
		var err error
		if wire, err = os.ReadFile(path); err != nil {
			return nil, err
		}
	} else {
		read, unchanged, err := profileBytes(path, cachedBuf)
		if err != nil {
			return nil, err
		}
		if unchanged {
			return cached, nil
		}
		wire = read
	}

	snapshot, err := parseProfileSnapshot(wire)
	if err != nil {
		return nil, err
	}
	if len(wire) > maxCachedProfileSize {
		return snapshot, nil
	}

	profileCache.mu.Lock()
	// The read hands back a buffer nobody else holds, and the parse keeps its
	// own copies, so the wire bytes can be cached as they are.
	profileCache.buf = wire
	profileCache.snapshot = snapshot
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
	profileCache.snapshot = nil
	profileCache.mu.Unlock()
}
