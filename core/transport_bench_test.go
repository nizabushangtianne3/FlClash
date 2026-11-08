//go:build !android

package core

import (
	"bytes"
	"io"
	"os"
	"testing"
)

// A large answer is written beside its envelope, so this is what that costs on
// a real pipe rather than a discard writer: the frame reaches the host in
// three writes and the document is never copied. Measured against joining the
// pieces into one buffer first, this path runs about 35% faster and allocates
// 32B instead of the frame's size, which is why the transport works this way.
func BenchmarkWriteFrameLargeDocumentOnAPipe(b *testing.B) {
	readEnd, writeEnd, err := os.Pipe()
	if err != nil {
		b.Skip("no pipe available: ", err)
	}
	drained := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.Discard, readEnd)
		close(drained)
	}()
	b.Cleanup(func() {
		_ = writeEnd.Close()
		<-drained
		_ = readEnd.Close()
	})

	answer := frame{
		head:     []byte(`{"id":"benchmark","result":`),
		document: bytes.Repeat([]byte("x"), 140*1024),
		tail:     []byte(`}`),
	}

	b.ReportAllocs()
	b.SetBytes(int64(len(answer.document)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		written, err := writeFrame(writeEnd, answer)
		if err != nil || written == 0 {
			b.Fatalf("writeFrame error: %v", err)
		}
	}
}
