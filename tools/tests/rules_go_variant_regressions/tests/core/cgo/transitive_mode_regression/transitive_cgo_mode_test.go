package transitive_mode_regression

import (
	"testing"

	"github.com/bazelbuild/rules_go/tests/core/cgo/transitive_mode_regression/middle"
)

func TestTransitiveCgoDependencyBuildsInCompatibleMode(t *testing.T) {
	if got, want := middle.Answer(), 42; got != want {
		t.Fatalf("Answer() = %d, want %d", got, want)
	}
}
