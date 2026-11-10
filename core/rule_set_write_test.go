package core

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

// A rule set is written through a temp file and renamed into place, so a
// reader never sees a half-written set. The write is the only path the host
// itself owns, and its failures are the ones worth pinning.
func TestWriteRuleSetFileReplacesWhatStoodThere(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "set.yaml")

	require.NoError(t, writeRuleSetFile(path, []byte("payload:\n  - example.com\n")))
	written, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Equal(t, "payload:\n  - example.com\n", string(written))

	// A set that stood there is replaced, and the temp file is not left behind.
	require.NoError(t, writeRuleSetFile(path, []byte("payload:\n  - example.org\n")))
	replaced, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Equal(t, "payload:\n  - example.org\n", string(replaced))
	_, err = os.Stat(path + ".tmp")
	require.True(t, os.IsNotExist(err), "the temp file must not outlive the write")
}

// The set is written beside its source, so a parent that cannot be a directory
// is reported rather than worked around.
func TestWriteRuleSetFileReportsAParentThatCannotBeADirectory(t *testing.T) {
	dir := t.TempDir()
	blocker := filepath.Join(dir, "not-a-dir")
	require.NoError(t, os.WriteFile(blocker, []byte("plain"), 0o644))

	err := writeRuleSetFile(filepath.Join(blocker, "set.yaml"), []byte("payload:\n"))
	require.Error(t, err)
}

// A rename onto a directory cannot succeed, and the temp file is taken with
// it rather than left in the cache.
func TestWriteRuleSetFileCleansUpWhenTheRenameFails(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "set.yaml")
	require.NoError(t, os.Mkdir(path, 0o755))

	err := writeRuleSetFile(path, []byte("payload:\n"))
	require.Error(t, err)
	_, statErr := os.Stat(path + ".tmp")
	require.True(t, os.IsNotExist(statErr),
		"a failed write takes its temp file with it")
}
