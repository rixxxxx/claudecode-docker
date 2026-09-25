package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// m is the marker line withMirroredNetworking writes, given the previous value.
func m(prev string) string { return wslconfigMarker + prev + "\n" }

const mirrored = "networkingMode=mirrored\n"

func TestWithMirroredNetworking(t *testing.T) {
	cases := []struct {
		name, in, want string
		changed        bool
	}{
		{"empty", "", "[wsl2]\n" + m("(unset)") + mirrored, true},
		{
			"other section only, no trailing newline",
			"[experimental]\nautoMemoryReclaim=gradual",
			"[experimental]\nautoMemoryReclaim=gradual\n[wsl2]\n" + m("(unset)") + mirrored, true,
		},
		{"already set", "[wsl2]\n" + mirrored, "[wsl2]\n" + mirrored, false},
		{"already set, different case", "[WSL2]\nNetworkingMode=Mirrored\n", "[WSL2]\nNetworkingMode=Mirrored\n", false},
		{"nat replaced", "[wsl2]\nmemory=8GB\nnetworkingMode=nat\n", "[wsl2]\nmemory=8GB\n" + m("networkingMode=nat") + mirrored, true},
		{
			"section exists, setting missing, keeps other keys",
			"[wsl2]\nmemory=8GB\n",
			"[wsl2]\n" + m("(unset)") + mirrored + "memory=8GB\n", true,
		},
		{
			"wsl2 not last, setting under a later section is ignored",
			"[wsl2]\nmemory=8GB\n[experimental]\nnetworkingMode=nat\n",
			"[wsl2]\n" + m("(unset)") + mirrored + "memory=8GB\n[experimental]\nnetworkingMode=nat\n", true,
		},
		{"CRLF", "[wsl2]\r\nmemory=8GB\r\n", "[wsl2]\n" + m("(unset)") + mirrored + "memory=8GB\n", true},
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

func TestWithoutMirroredNetworking(t *testing.T) {
	cases := []struct {
		name, in, want string
		changed        bool
	}{
		{"restores previous value", "[wsl2]\nmemory=8GB\n" + m("networkingMode=nat") + mirrored, "[wsl2]\nmemory=8GB\nnetworkingMode=nat\n", true},
		{"removes setting that was unset", "[wsl2]\n" + m("(unset)") + mirrored + "memory=8GB\n", "[wsl2]\nmemory=8GB\n", true},
		{"user's own setting is left alone", "[wsl2]\n" + mirrored, "[wsl2]\n" + mirrored, false},
		{"no .wslconfig content", "", "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, changed := withoutMirroredNetworking(c.in)
			if got != c.want || changed != c.changed {
				t.Errorf("withoutMirroredNetworking(%q) = (%q, %v), want (%q, %v)", c.in, got, changed, c.want, c.changed)
			}
		})
	}

	// Round trip: install then uninstall leaves the user's other settings as
	// they were.
	orig := "[experimental]\nautoMemoryReclaim=gradual\n[wsl2]\nmemory=8GB\nnetworkingMode=nat\n"
	added, _ := withMirroredNetworking(orig)
	if reverted, _ := withoutMirroredNetworking(added); reverted != orig {
		t.Errorf("round trip: got %q, want %q", reverted, orig)
	}
}

func TestParseDistroList(t *testing.T) {
	// UTF-16LE as printed by older wsl.exe builds that ignore WSL_UTF8=1.
	utf16ish := "U\x00b\x00u\x00n\x00t\x00u\x00\r\x00\n\x00C\x00l\x00a\x00u\x00d\x00e\x00C\x00o\x00d\x00e\x00S\x00a\x00n\x00d\x00b\x00o\x00x\x00\r\x00\n\x00"
	got := parseDistroList(utf16ish)
	if strings.Join(got, ",") != "Ubuntu,"+distroName {
		t.Errorf("got %q", got)
	}
	if got := parseDistroList(""); len(got) != 0 {
		t.Errorf("empty output: got %q", got)
	}
}

func TestLatestWSLImage(t *testing.T) {
	h := strings.Repeat("a", 64)
	sums := h + " *ubuntu-26.04-wsl-amd64.wsl\n" +
		h + " *ubuntu-26.04.2-wsl-amd64.wsl\n" +
		h + " *ubuntu-26.04.10-wsl-amd64.wsl\n" + // numeric, not lexical, order
		h + " *ubuntu-26.04.11-wsl-arm64.wsl\n" + // wrong arch
		h + " *ubuntu-26.04.12-desktop-amd64.iso\n"
	if got, ok := latestWSLImage(sums); !ok || got != "ubuntu-26.04.10-wsl-amd64.wsl" {
		t.Errorf("got (%q, %v)", got, ok)
	}
	if _, ok := latestWSLImage(h + " *ubuntu-26.04-desktop-amd64.iso\n"); ok {
		t.Error("found a WSL image where there is none")
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

func TestSplitURL(t *testing.T) {
	dir, name := splitURL("https://example.org/releases/26.04/ubuntu-wsl.tar.gz")
	if dir != "https://example.org/releases/26.04/" || name != "ubuntu-wsl.tar.gz" {
		t.Errorf("got (%q, %q)", dir, name)
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

func TestFindLocalImage(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"ubuntu-26.04.1-wsl-amd64.wsl", "SHA256SUMS_ubuntu-26.04", "SHA256SUMS_ubuntu-26.04.gpg", "notes.txt"} {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	img, sums, err := findLocalImage(dir)
	if err != nil {
		t.Fatal(err)
	}
	if img != filepath.Join(dir, "ubuntu-26.04.1-wsl-amd64.wsl") || sums != filepath.Join(dir, "SHA256SUMS_ubuntu-26.04") {
		t.Errorf("got (%q, %q)", img, sums)
	}

	os.Remove(filepath.Join(dir, "SHA256SUMS_ubuntu-26.04.gpg"))
	if _, _, err := findLocalImage(dir); err == nil {
		t.Error("missing .gpg signature not reported")
	}

	os.WriteFile(filepath.Join(dir, "SHA256SUMS_ubuntu-26.04.gpg"), nil, 0o644)
	os.WriteFile(filepath.Join(dir, "second.wsl"), nil, 0o644)
	if _, _, err := findLocalImage(dir); err == nil {
		t.Error("two .wsl images not reported as ambiguous")
	}
}
