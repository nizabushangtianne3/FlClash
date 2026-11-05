package core

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/component/age"
)

func TestReadProfileRetagsShortIDsAndReusesTheSnapshot(t *testing.T) {
	t.Cleanup(forgetProfileRaw)

	path := writeBaseProfile(t, baseProfile)
	first, err := readProfile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !first.retag {
		t.Fatal("retag = false, want the profile classified as short-id-bearing")
	}
	if got := first.raw.Proxy[1]["reality-opts"].(map[string]any)["short-id"]; got != "0123" {
		t.Fatalf("short-id = %#v, want the literal 0123", got)
	}

	second, err := readProfile(path)
	if err != nil {
		t.Fatalf("read unchanged: %v", err)
	}
	if second.raw != first.raw || second.document != first.document {
		t.Error("an unchanged profile was parsed again")
	}
	if second.digest != first.digest || second.retag != first.retag {
		t.Error("an unchanged profile changed its cached metadata")
	}

	changed := writeBaseProfile(t, strings.Replace(baseProfile, "short-id: 0123", "short-id: 0456", 1))
	third, err := readProfile(changed)
	if err != nil {
		t.Fatalf("read changed: %v", err)
	}
	if third.raw == first.raw || third.document == first.document {
		t.Error("a changed profile was answered from the byte cache")
	}
	if got := third.raw.Proxy[1]["reality-opts"].(map[string]any)["short-id"]; got != "0456" {
		t.Fatalf("changed short-id = %#v, want the literal 0456", got)
	}
}

func TestReadProfileDigestsTheEncryptedWireBytes(t *testing.T) {
	secretKey, publicKey, err := age.GenX25519KeyPair()
	if err != nil {
		t.Fatalf("generate key pair: %v", err)
	}
	age.SetGlobalSecretKeys(secretKey)
	defer age.SetGlobalSecretKeys()

	encrypted, err := age.EncryptBytes([]byte("mixed-port: 7890\n"), publicKey)
	if err != nil {
		t.Fatalf("encrypt profile: %v", err)
	}
	path := writeBaseProfile(t, string(encrypted))
	snapshot, err := readProfile(path)
	if err != nil {
		t.Fatalf("read profile: %v", err)
	}

	want := sha256.Sum256(encrypted)
	if snapshot.digest != hex.EncodeToString(want[:]) {
		t.Fatalf("digest = %s, want the SHA256 of the encrypted wire bytes", snapshot.digest)
	}
	if snapshot.retag {
		t.Error("retag = true, want the encrypted plaintext to be short-id-free")
	}
}
