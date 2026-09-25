package main

import (
	"os"
	"strings"
	"testing"
)

// testdata/SHA256SUMS(.gpg) are Canonical's real, unmodified Ubuntu 26.04
// release files (signed 2026-08-27 by the CD Image key) -- cross-checked
// with `gpgv --keyring /usr/share/keyrings/ubuntu-archive-keyring.gpg`.

func readTestdata(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestTrustedKeysMatchPinnedFingerprints(t *testing.T) {
	keys, err := trustedKeys()
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 1 || keys[0].fingerprint != "843938DF228D22F7B3742BC0D94AA3F0EFE21092" || keys[0].pub.N.BitLen() != 4096 {
		t.Errorf("unexpected trusted keys: %+v", keys)
	}
}

func TestVerifyCanonicalSignature(t *testing.T) {
	keys, err := trustedKeys()
	if err != nil {
		t.Fatal(err)
	}
	sums, sig := readTestdata(t, "SHA256SUMS"), readTestdata(t, "SHA256SUMS.gpg")

	key, err := verifyDetachedSignature(sums, sig, keys)
	if err != nil {
		t.Fatalf("real Canonical signature rejected: %v", err)
	}
	if key.fingerprint != "843938DF228D22F7B3742BC0D94AA3F0EFE21092" {
		t.Errorf("verified by unexpected key %s", key.fingerprint)
	}

	// Signed SHA256SUMS lists the exact image the default URL points to.
	_, name := sha256SumsURL(defaultRootfsURL)
	if got, ok := parseSHA256Sums(string(sums), name); !ok || got != "48d56724b5c8e60f24893e83e73bbb58c60b3ca22fba3da977075420acd54104" {
		t.Errorf("%s: got (%q, %v)", name, got, ok)
	}
}

func TestVerifyRejectsTamperedData(t *testing.T) {
	keys, _ := trustedKeys()
	sums, sig := readTestdata(t, "SHA256SUMS"), readTestdata(t, "SHA256SUMS.gpg")

	// Swap one hash for an attacker's -- same length, same format.
	tampered := []byte(strings.Replace(string(sums), "48d56724", "00000000", 1))
	if _, err := verifyDetachedSignature(tampered, sig, keys); err == nil {
		t.Error("tampered SHA256SUMS accepted")
	}
	if _, err := verifyDetachedSignature(sums, sig, nil); err == nil {
		t.Error("signature accepted with no trusted keys")
	}
	if _, err := verifyDetachedSignature(sums, []byte("not a signature"), keys); err == nil {
		t.Error("garbage signature accepted")
	}
	// Flip one bit inside the RSA signature itself (past the headers).
	raw, err := dearmor(sig)
	if err != nil {
		t.Fatal(err)
	}
	raw[len(raw)-10] ^= 0x01
	if _, err := verifyDetachedSignature(sums, raw, keys); err == nil {
		t.Error("corrupted signature accepted")
	}
}
