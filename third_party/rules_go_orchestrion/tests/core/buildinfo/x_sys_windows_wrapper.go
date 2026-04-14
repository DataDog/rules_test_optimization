//go:build windows

package xsyswrapperwindows

import "golang.org/x/sys/windows"

// WindowsErrno exposes one x/sys symbol so the binary keeps the external
// module in the dependency graph while the package_info metadata provides the
// real module version for BuildInfo.
func WindowsErrno() windows.Errno {
	return windows.ERROR_FILE_NOT_FOUND
}
