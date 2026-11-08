package core

// answerFrame reads a frameWriter the way the transport delivers it: the
// envelope the call names around the document the result encoded.
func answerFrame(writer frameWriter, id string) []byte {
	return frame{head: envelope(id), document: writer.document(), tail: responseTail}.bytes()
}

// answerBytes reads one call the way the transport delivers it.
func answerBytes(call MethodCall) []byte {
	return handleMethodCall(&call).bytes()
}
