// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

//go:build !plan9

package constrained_test

import "testing"

// Every source of constrained_test has a negated build constraint.
func TestConstrained(t *testing.T) {}
