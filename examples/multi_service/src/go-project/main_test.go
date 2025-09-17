package main

import (
  "io"
  "bytes"
  "os"
  "testing"
)

func TestGreeting(t *testing.T) {
  if getGreeting() != "Hello, World!" { t.Fatal("unexpected greeting") }
}

func TestMainOutput(t *testing.T) {
  old := os.Stdout
  r, w, _ := os.Pipe()
  os.Stdout = w
  main()
  w.Close()
  os.Stdout = old
  var buf bytes.Buffer
  io.Copy(&buf, r)
  if buf.String() != "Hello, World!\n" { t.Fatal("unexpected output") }
}

