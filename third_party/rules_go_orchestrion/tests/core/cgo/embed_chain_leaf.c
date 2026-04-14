#include "tests/core/cgo/embed_chain_leaf.h"

void embedChainLeaf(void) {
    embedChainLeafDep();
    embedChainMid();
    embedChainTop();
}
