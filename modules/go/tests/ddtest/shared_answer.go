// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package sharedanswer

// int shared_answer(void);
import "C"

func Answer() int { return int(C.shared_answer()) }
