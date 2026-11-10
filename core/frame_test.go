package core

// answerFrame reads a frameWriter the way the transport delivers it: the
// envelope the call names around the document the result encoded.
func answerFrame(writer frameWriter, id string) []byte {
	return frame{document: writer.document(), tail: responseTail, id: id}.bytes()
}

// answerBytes reads one call the way the transport delivers it.
func answerBytes(call MethodCall) []byte {
	return handleMethodCall(&call).bytes()
}
