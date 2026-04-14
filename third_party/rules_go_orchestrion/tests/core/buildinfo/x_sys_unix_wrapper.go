//go:build unix

package xsyswrapperunix

import "golang.org/x/sys/unix"

// UnixErrno exposes one x/sys symbol so the binary keeps the external module in
// the dependency graph while the package_info metadata provides the real module
// version for BuildInfo.
func UnixErrno() unix.Errno {
	return unix.ENOENT
}
