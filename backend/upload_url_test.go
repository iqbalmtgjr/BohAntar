package main

import "testing"

func TestIsUploadedFileURL(t *testing.T) {
	ok := []string{"/uploads/f_123.jpg", "/uploads/f_123.PDF", "/uploads/f_123.heic"}
	bad := []string{
		"", "/uploads/", "uploads/f.jpg",
		"https://evil.example/x.jpg",
		"/uploads/../../etc/passwd",
		"/uploads/sub/f.jpg",
		"/uploads/f.svg", // SVG bisa membawa script saat dibuka admin
		"/uploads/f",
	}
	for _, u := range ok {
		if !isUploadedFileURL(u) {
			t.Errorf("seharusnya diterima: %q", u)
		}
	}
	for _, u := range bad {
		if isUploadedFileURL(u) {
			t.Errorf("seharusnya ditolak: %q", u)
		}
	}
}
