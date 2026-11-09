//go:build !(linux && (amd64 || arm64))

package main

import "net"

// dengarPort di luar Linux (laptop pengembang): port biasa. Pergantian tanpa
// jeda hanya diperlukan di VPS.
func dengarPort(addr string) (net.Listener, error) { return net.Listen("tcp", addr) }
