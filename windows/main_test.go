package main

import (
	"strings"
	"testing"
)

func TestWithMirroredNetworking(t *testing.T) {
	cases := []struct {
		name, in, want string
		changed        bool
	}{
		{"empty", "", "[wsl2]\nnetworkingMode=mirrored\n", true},
		{
			"other section only, no trailing newline",
			"[experimental]\nautoMemoryReclaim=gradual",
			"[experimental]\nautoMemoryReclaim=gradual\n[wsl2]\nnetworkingMode=mirrored\n", true,
		},
		{"already set", "[wsl2]\nnetworkingMode=mirrored\n", "[wsl2]\nnetworkingMode=mirrored\n", false},
		{"already set, different case", "[WSL2]\nNetworkingMode=Mirrored\n", "[WSL2]\nNetworkingMode=Mirrored\n", false},
		{"nat replaced", "[wsl2]\nmemory=8GB\nnetworkingMode=nat\n", "[wsl2]\nmemory=8GB\nnetworkingMode=mirrored\n", true},
		{
			"section exists, setting missing, keeps other keys",
			"[wsl2]\nmemory=8GB\n",
			"[wsl2]\nnetworkingMode=mirrored\nmemory=8GB\n", true,
		},
		{
			"wsl2 not last, setting under a later section is ignored",
			"[wsl2]\nmemory=8GB\n[experimental]\nnetworkingMode=nat\n",
			"[wsl2]\nnetworkingMode=mirrored\nmemory=8GB\n[experimental]\nnetworkingMode=nat\n", true,
		},
		{"CRLF", "[wsl2]\r\nmemory=8GB\r\n", "[wsl2]\nnetworkingMode=mirrored\nmemory=8GB\n", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, changed := withMirroredNetworking(c.in)
			if got != c.want || changed != c.changed {
				t.Errorf("withMirroredNetworking(%q) = (%q, %v), want (%q, %v)", c.in, got, changed, c.want, c.changed)
			}
		})
	}
}

func TestLinuxUsername(t *testing.T) {
	cases := []struct{ in, want string }{
		{"KBartha", "kbartha"},
		{"Max Mustermann", "maxmustermann"},
		{"jörg.müller", "jrgmller"},
		{"123abc", "abc"},
		{"-dash", "dash"},
		{"", fallbackUsername},
		{"Администратор", fallbackUsername},
		{"root", fallbackUsername},
		{"Root", fallbackUsername},
		{"a_very_long_username_exceeding_32", "a_very_long_username_exceeding_3"},
	}
	for _, c := range cases {
		if got := linuxUsername(c.in); got != c.want {
			t.Errorf("linuxUsername(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestSHA256SumsURL(t *testing.T) {
	sums, name := sha256SumsURL("https://example.org/releases/26.04/ubuntu-wsl.tar.gz")
	if sums != "https://example.org/releases/26.04/SHA256SUMS" || name != "ubuntu-wsl.tar.gz" {
		t.Errorf("got (%q, %q)", sums, name)
	}
}

func TestParseSHA256Sums(t *testing.T) {
	hashA := strings.Repeat("A", 64)
	hashB := strings.Repeat("b", 64)
	sums := hashA + " *ubuntu-a.tar.gz\r\n" + hashB + "  ubuntu-b.wsl\n\ngarbage line here\n"

	if got, ok := parseSHA256Sums(sums, "ubuntu-a.tar.gz"); !ok || got != strings.ToLower(hashA) {
		t.Errorf("binary-mode entry: got (%q, %v)", got, ok)
	}
	if got, ok := parseSHA256Sums(sums, "ubuntu-b.wsl"); !ok || got != hashB {
		t.Errorf("text-mode entry: got (%q, %v)", got, ok)
	}
	if _, ok := parseSHA256Sums(sums, "missing.tar.gz"); ok {
		t.Error("missing entry reported as found")
	}
	if _, ok := parseSHA256Sums("tooshort  ubuntu-a.tar.gz\n", "ubuntu-a.tar.gz"); ok {
		t.Error("non-64-char hash accepted")
	}
}

func TestPSQuote(t *testing.T) {
	if got := psQuote(`C:\Users\O'Brien\setup.exe`); got != `'C:\Users\O''Brien\setup.exe'` {
		t.Errorf("got %s", got)
	}
}
