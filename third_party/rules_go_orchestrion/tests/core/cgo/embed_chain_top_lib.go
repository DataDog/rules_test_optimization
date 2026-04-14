package embedchain

// CallEmbeddedChain keeps the final cdeps contributor in a pure-Go embed hop
// so link-only native deps must survive all the way to the binary.
func CallEmbeddedChain() {
	CallEmbeddedLeaf()
}
