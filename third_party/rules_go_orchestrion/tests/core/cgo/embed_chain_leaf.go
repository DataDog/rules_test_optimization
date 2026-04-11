package embedchain

/*
void embedChainLeaf(void);
*/
import "C"

// CallLeafSymbol exercises the leaf cgo archive so the final binary must keep
// every native dependency contributed through the embed chain.
func CallLeafSymbol() {
	C.embedChainLeaf()
}
