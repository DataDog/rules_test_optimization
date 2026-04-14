package embedchain

// CallEmbeddedLeaf preserves a pure-Go embed hop between the cgo leaf and the
// final binary so native deps must propagate through the chain.
func CallEmbeddedLeaf() {
	CallLeafSymbol()
}
