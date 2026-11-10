package core

import (
	"os"
	"path/filepath"

	"github.com/metacubex/mihomo/constant"
)

// Android copies a reply into the Java heap three times and the desktop IPC
// frame stops at maxIPCFrameSize. The directory name is mirrored in Dart.
const (
	responseSpillThreshold = 1 << 20
	spilledResponseDirName = "responses"
)

var spillThreshold = responseSpillThreshold

func spilledResponseDir() string {
	return filepath.Join(constant.Path.HomeDir(), spilledResponseDirName)
}

// The host deletes each file as soon as it reads it, which a directory an
// elevated Core just made would refuse until the debounced reclaim.
func makeSpilledResponseDir() (string, error) {
	dir := spilledResponseDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	reclaimDirOwnership(dir)
	return dir, nil
}

func spillFrame(id string, answer frame) frame {
	if answer.size() <= spillThreshold {
		return answer
	}
	path, err := writeSpilledFrame(answer)
	if err != nil {
		logError("spill response %s: %v", id, err)
		return answer
	}
	return frame{head: encodeResponse(MethodResponse{ID: id, File: path})}
}

func writeSpilledFrame(answer frame) (path string, err error) {
	if len(answer.head) == 0 {
		answer.head = envelope(answer.id)
	}
	dir, err := makeSpilledResponseDir()
	if err != nil {
		return "", err
	}
	file, err := os.CreateTemp(dir, "*.json")
	if err != nil {
		return "", err
	}
	path = file.Name()
	defer func() {
		if err != nil {
			_ = os.Remove(path)
		}
	}()
	// An elevated Core still answers a host running as the app user.
	if err := file.Chmod(0o644); err != nil {
		_ = file.Close()
		return "", err
	}
	for _, piece := range [][]byte{answer.head, answer.document, answer.tail} {
		if _, err := file.Write(piece); err != nil {
			_ = file.Close()
			return "", err
		}
	}
	if err := file.Close(); err != nil {
		return "", err
	}
	scheduleReclaimOwnership()
	return path, nil
}

func clearSpilledResponses() {
	entries, err := os.ReadDir(spilledResponseDir())
	if err != nil {
		return
	}
	for _, entry := range entries {
		_ = os.Remove(filepath.Join(spilledResponseDir(), entry.Name()))
	}
}
