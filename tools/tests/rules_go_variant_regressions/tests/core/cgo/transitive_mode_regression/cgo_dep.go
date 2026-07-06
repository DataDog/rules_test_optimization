package cgo_dep

/*
int rulesGoOrchestrionTransitiveAnswer() {
	return 42;
}
*/
import "C"

func Answer() int {
	return int(C.rulesGoOrchestrionTransitiveAnswer())
}
