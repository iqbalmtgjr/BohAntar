//go:build linux && (amd64 || arm64)

package main

import (
	"context"
	"net"
	"syscall"
)

// dengarPort membuka port dengan SO_REUSEPORT supaya binary baru bisa mulai
// melayani di port yang sama selagi yang lama menuntaskan permintaannya
// (lihat berhenti_rapi.go dan ganti-binary.sh). Kernel hanya mengizinkan ini
// untuk proses dengan pengguna yang sama.
//
// ponytail: syscall bawaan tidak punya SO_REUSEPORT untuk Linux; nilainya 15 di
// amd64/arm64 (build tag di atas). Pindah ke golang.org/x/sys/unix kalau VPS-nya
// suatu hari berarsitektur lain.
const soReusePort = 0xf

func dengarPort(addr string) (net.Listener, error) {
	lc := net.ListenConfig{Control: func(_, _ string, c syscall.RawConn) error {
		var errSet error
		if err := c.Control(func(fd uintptr) {
			errSet = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, soReusePort, 1)
		}); err != nil {
			return err
		}
		return errSet
	}}
	return lc.Listen(context.Background(), "tcp", addr)
}
