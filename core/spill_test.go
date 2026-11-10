package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/stretchr/testify/require"
)

func withSpillHome(t *testing.T, threshold int) string {
	t.Helper()
	previousHome := constant.Path.HomeDir()
	previousThreshold := spillThreshold
	home := t.TempDir()
	constant.SetHomeDir(home)
	spillThreshold = threshold
	t.Cleanup(func() {
		constant.SetHomeDir(previousHome)
		spillThreshold = previousThreshold
	})
	return home
}

func getConfigCall(t *testing.T, id string) *MethodCall {
	t.Helper()
	path := filepath.Join(t.TempDir(), "profile.yaml")
	if err := os.WriteFile(path, []byte("mode: rule\nrules:\n  - MATCH,DIRECT\n"), 0o600); err != nil {
		t.Fatalf("write profile: %v", err)
	}
	arguments, _ := json.Marshal(PathParams{Path: path})
	return &MethodCall{ID: id, Method: configReadMethod, Arguments: arguments}
}

func TestHandleMethodCallSpillsALargeResultToAFile(t *testing.T) {
	home := withSpillHome(t, 64)

	frame := answerBytes(*getConfigCall(t, "7"))

	var envelope MethodResponse
	if err := json.Unmarshal(frame, &envelope); err != nil {
		t.Fatalf("response is not valid JSON: %v", err)
	}
	if envelope.ID != "7" || envelope.Result != nil || envelope.Error != nil {
		t.Fatalf("envelope = %+v, want only the id and the file", envelope)
	}
	if filepath.Dir(envelope.File) != filepath.Join(home, spilledResponseDirName) {
		t.Fatalf("file = %s, want it under the home directory's spill directory", envelope.File)
	}
	data, err := os.ReadFile(envelope.File)
	if err != nil {
		t.Fatalf("read spilled response: %v", err)
	}
	var spilled struct {
		ID     string         `json:"id"`
		Result map[string]any `json:"result"`
	}
	if err := json.Unmarshal(data, &spilled); err != nil {
		t.Fatalf("spilled response is not valid JSON: %v", err)
	}
	if spilled.ID != "7" || spilled.Result["mode"] != "rule" {
		t.Errorf("spilled response = %+v, want the full answer to call 7", spilled)
	}
	if runtime.GOOS != "windows" {
		info, _ := os.Stat(envelope.File)
		if info.Mode().Perm() != 0o644 {
			t.Errorf("mode = %v, want the host to be able to read it", info.Mode().Perm())
		}
	}
}

func TestHandleMethodCallAnswersInlineUnderTheThreshold(t *testing.T) {
	home := withSpillHome(t, responseSpillThreshold)

	frame := answerBytes(*getConfigCall(t, "8"))

	var envelope MethodResponse
	if err := json.Unmarshal(frame, &envelope); err != nil {
		t.Fatalf("response is not valid JSON: %v", err)
	}
	if envelope.File != "" || envelope.Result == nil {
		t.Errorf("envelope = %+v, want the result inline", envelope)
	}
	if _, err := os.Stat(filepath.Join(home, spilledResponseDirName)); !os.IsNotExist(err) {
		t.Errorf("stat spill directory = %v, want nothing written", err)
	}
}

// A frame writer's answer is written to the spill file in pieces, so the file
// the host reads has to hold the very bytes the transport would have written.
func TestHandleMethodCallSpillsAFrameWriterDocument(t *testing.T) {
	home := withSpillHome(t, responseSpillThreshold)

	group := proxyGroup(t, "group", "selector", "member-a", "member-b")
	tunnel.UpdateProxies(map[string]constant.Proxy{"group": group}, nil)
	config.SetProxyNameList([]string{"group"})
	t.Cleanup(func() {
		tunnel.UpdateProxies(nil, nil)
		config.SetProxyNameList(nil)
	})

	call := MethodCall{ID: "spill", Method: proxyListMethod}
	inline := answerBytes(call)

	// One byte under the answer's size is enough to force the spill.
	spillThreshold = len(inline) - 1
	spilled := handleMethodCall(&call)

	var envelope MethodResponse
	require.NoError(t, json.Unmarshal(spilled.bytes(), &envelope))
	if envelope.ID != "spill" || envelope.Result != nil || envelope.Error != nil {
		t.Fatalf("envelope = %+v, want only the id and the file", envelope)
	}
	if filepath.Dir(envelope.File) != filepath.Join(home, spilledResponseDirName) {
		t.Fatalf("file = %s, want it under the home directory's spill directory", envelope.File)
	}
	written, err := os.ReadFile(envelope.File)
	if err != nil {
		t.Fatalf("read spilled response: %v", err)
	}
	if string(written) != string(inline) {
		t.Errorf("spilled response is %d bytes, want the %d the transport would have written",
			len(written), len(inline))
	}
}

// A spill that cannot be written must not lose the answer: the host reads it
// inline, over the frame limit, rather than getting a file that is not there.
func TestSpillFailureAnswersInline(t *testing.T) {
	home := withSpillHome(t, 64)
	blocker := filepath.Join(t.TempDir(), "not-a-directory")
	require.NoError(t, os.WriteFile(blocker, []byte("x"), 0o600))
	constant.SetHomeDir(blocker)
	t.Cleanup(func() { constant.SetHomeDir(home) })

	group := proxyGroup(t, "group", "selector", "member-a", "member-b")
	tunnel.UpdateProxies(map[string]constant.Proxy{"group": group}, nil)
	config.SetProxyNameList([]string{"group"})
	t.Cleanup(func() {
		tunnel.UpdateProxies(nil, nil)
		config.SetProxyNameList(nil)
	})

	call := MethodCall{ID: "unwritable", Method: proxyListMethod}
	inline := answerBytes(call)

	spilled := handleMethodCall(&call)
	if string(spilled.bytes()) != string(inline) {
		t.Errorf("answer = %d bytes, want the inline answer of %d", spilled.size(), len(inline))
	}
}

func TestClearSpilledResponsesKeepsTheDirectory(t *testing.T) {
	home := withSpillHome(t, 64)
	answerBytes(*getConfigCall(t, "9"))

	clearSpilledResponses()

	entries, err := os.ReadDir(filepath.Join(home, spilledResponseDirName))
	if err != nil {
		t.Fatalf("read spill directory: %v", err)
	}
	if len(entries) != 0 {
		t.Errorf("entries = %v, want none left", entries)
	}
}
