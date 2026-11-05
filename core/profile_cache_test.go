package core

import (
	"testing"
)

func TestReadProfileDocumentReusesOnlyUnchangedBytes(t *testing.T) {
	buf := profileDocument(8)

	first, err := readProfileDocument(buf)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	second, err := readProfileDocument(buf)
	if err != nil {
		t.Fatalf("read unchanged: %v", err)
	}
	if first != second {
		t.Error("an unchanged profile document was parsed again")
	}

	changed := append([]byte(nil), buf...)
	changed = append(changed, "# changed\n"...)
	third, err := readProfileDocument(changed)
	if err != nil {
		t.Fatalf("read changed: %v", err)
	}
	if third == first {
		t.Error("a changed profile document was answered from the byte cache")
	}
}
