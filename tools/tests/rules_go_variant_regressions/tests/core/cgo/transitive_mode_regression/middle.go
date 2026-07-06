package middle

import "github.com/bazelbuild/rules_go/tests/core/cgo/transitive_mode_regression/cgo_dep"

func Answer() int {
	return cgo_dep.Answer()
}
