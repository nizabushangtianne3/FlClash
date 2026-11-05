package core

import (
	"testing"
)

func TestReadProfileDocumentReusesOnlyUnchangedBytes(t *testing.T) {
	buf := append(profileDocument(8), []byte("# short-id\n")...)

	first, firstRetag, err := readProfileDocument(buf)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	second, secondRetag, err := readProfileDocument(buf)
	if err != nil {
		t.Fatalf("read unchanged: %v", err)
	}
	if firstRetag != secondRetag {
		t.Fatalf("cached retag = %v, want %v", secondRetag, firstRetag)
	}
	if !firstRetag {
		t.Fatal("the short-id scan was not cached")
	}
	if first != second {
		t.Error("an unchanged profile document was parsed again")
	}

	changed := append([]byte(nil), buf...)
	changed = append(changed, "# changed\n"...)
	third, thirdRetag, err := readProfileDocument(changed)
	if err != nil {
		t.Fatalf("read changed: %v", err)
	}
	if third == first {
		t.Error("a changed profile document was answered from the byte cache")
	}
	if thirdRetag != firstRetag {
		t.Errorf("changed retag = %v, want the same short-id classification", thirdRetag)
	}
}
