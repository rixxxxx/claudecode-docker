// Minimal OpenPGP (RFC 4880) detached-signature verification, stdlib only,
// for checking Canonical's SHA256SUMS.gpg before trusting SHA256SUMS -- a
// stock Windows machine has no gpg.exe, and golang.org/x/crypto/openpgp is
// deprecated. Deliberately narrow: v4 RSA keys, v4 binary-document
// signatures (type 0x00), SHA-256/384/512. That's exactly what Canonical
// publishes; anything else is rejected rather than half-supported.
package main

import (
	"bytes"
	"crypto"
	"crypto/rsa"
	"crypto/sha1"
	_ "crypto/sha512" // registers SHA-384/512 for crypto.Hash.New
	_ "embed"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"strings"
)

// Exported from the ubuntu-keyring package's
// /usr/share/keyrings/ubuntu-archive-keyring.gpg (apt-verified, dpkg -V
// clean) -- the key releases.ubuntu.com signs SHA256SUMS with.
//
//go:embed keys/ubuntu-cdimage-2012.asc
var embeddedKeyring []byte

// trustedFingerprints pins which keys from embeddedKeyring are actually
// trusted, so adding a key to that file alone can't silently widen trust.
var trustedFingerprints = map[string]string{
	"843938DF228D22F7B3742BC0D94AA3F0EFE21092": "Ubuntu CD Image Automatic Signing Key (2012)",
}

var errTruncated = errors.New("truncated OpenPGP data")

type pgpKey struct {
	fingerprint string // uppercase hex, v4 (SHA-1 over the key packet)
	pub         *rsa.PublicKey
}

type pgpPacket struct {
	tag  byte
	body []byte
}

func trustedKeys() ([]pgpKey, error) {
	all, err := parsePublicKeys(embeddedKeyring)
	if err != nil {
		return nil, fmt.Errorf("parsing embedded keyring: %w", err)
	}
	var keys []pgpKey
	for _, k := range all {
		if _, ok := trustedFingerprints[k.fingerprint]; ok {
			keys = append(keys, k)
		}
	}
	if len(keys) != len(trustedFingerprints) {
		return nil, fmt.Errorf("embedded keyring has %d of %d pinned keys", len(keys), len(trustedFingerprints))
	}
	return keys, nil
}

// dearmor strips ASCII armor if present; binary input is returned as-is.
// The CRC24 line is ignored -- the signature check itself covers integrity.
func dearmor(data []byte) ([]byte, error) {
	s := strings.ReplaceAll(string(data), "\r\n", "\n")
	begin := strings.Index(s, "-----BEGIN PGP ")
	if begin == -1 {
		return data, nil
	}
	lines := strings.Split(s[begin:], "\n")[1:]
	// Armor headers ("Version: ...") run up to the first blank line.
	i := 0
	for i < len(lines) && strings.TrimSpace(lines[i]) != "" {
		i++
	}
	if i == len(lines) {
		return nil, errors.New("malformed ASCII armor")
	}
	var b64 strings.Builder
	for _, l := range lines[i+1:] {
		l = strings.TrimSpace(l)
		if strings.HasPrefix(l, "=") || strings.HasPrefix(l, "-----END ") {
			break
		}
		b64.WriteString(l)
	}
	return base64.StdEncoding.DecodeString(b64.String())
}

// readPackets splits OpenPGP data into packets (old- and new-format
// headers; partial/indeterminate lengths aren't used for keys or
// signatures and are rejected).
func readPackets(data []byte) ([]pgpPacket, error) {
	var packets []pgpPacket
	for len(data) > 0 {
		hdr := data[0]
		if hdr&0x80 == 0 {
			return nil, errors.New("invalid OpenPGP packet header")
		}
		var tag byte
		var length, hdrLen int
		if hdr&0x40 != 0 {
			tag = hdr & 0x3f
			if len(data) < 2 {
				return nil, errTruncated
			}
			switch l := int(data[1]); {
			case l < 192:
				length, hdrLen = l, 2
			case l < 224:
				if len(data) < 3 {
					return nil, errTruncated
				}
				length, hdrLen = (l-192)<<8+int(data[2])+192, 3
			case l == 255:
				if len(data) < 6 {
					return nil, errTruncated
				}
				length, hdrLen = int(binary.BigEndian.Uint32(data[2:6])), 6
			default:
				return nil, errors.New("partial-length OpenPGP packets are not supported")
			}
		} else {
			tag = (hdr >> 2) & 0x0f
			switch hdr & 0x03 {
			case 0:
				hdrLen = 2
			case 1:
				hdrLen = 3
			case 2:
				hdrLen = 5
			default:
				return nil, errors.New("indeterminate-length OpenPGP packets are not supported")
			}
			if len(data) < hdrLen {
				return nil, errTruncated
			}
			switch hdrLen {
			case 2:
				length = int(data[1])
			case 3:
				length = int(binary.BigEndian.Uint16(data[1:3]))
			case 5:
				length = int(binary.BigEndian.Uint32(data[1:5]))
			}
		}
		if length < 0 || length > len(data)-hdrLen {
			return nil, errTruncated
		}
		packets = append(packets, pgpPacket{tag, data[hdrLen : hdrLen+length]})
		data = data[hdrLen+length:]
	}
	return packets, nil
}

func readMPI(b []byte) (mpi, rest []byte, err error) {
	if len(b) < 2 {
		return nil, nil, errTruncated
	}
	n := (int(binary.BigEndian.Uint16(b)) + 7) / 8
	if len(b) < 2+n {
		return nil, nil, errTruncated
	}
	return b[2 : 2+n], b[2+n:], nil
}

// parsePublicKeys returns every v4 RSA primary key and subkey in a
// (possibly armored) keyring; user IDs, certifications etc. are skipped.
func parsePublicKeys(data []byte) ([]pgpKey, error) {
	raw, err := dearmor(data)
	if err != nil {
		return nil, err
	}
	packets, err := readPackets(raw)
	if err != nil {
		return nil, err
	}
	var keys []pgpKey
	for _, p := range packets {
		b := p.body
		// tag 6 = public key, 14 = public subkey; version 4; algo 1/3 = RSA.
		if (p.tag != 6 && p.tag != 14) || len(b) < 6 || b[0] != 4 || (b[5] != 1 && b[5] != 3) {
			continue
		}
		n, rest, err := readMPI(b[6:])
		if err != nil {
			return nil, err
		}
		e, _, err := readMPI(rest)
		if err != nil {
			return nil, err
		}
		if len(e) > 4 {
			return nil, errors.New("unsupported RSA public exponent")
		}
		h := sha1.New()
		h.Write([]byte{0x99, byte(len(b) >> 8), byte(len(b))})
		h.Write(b)
		keys = append(keys, pgpKey{
			fingerprint: strings.ToUpper(hex.EncodeToString(h.Sum(nil))),
			pub: &rsa.PublicKey{
				N: new(big.Int).SetBytes(n),
				E: int(new(big.Int).SetBytes(e).Int64()),
			},
		})
	}
	return keys, nil
}

var pgpHashes = map[byte]crypto.Hash{8: crypto.SHA256, 9: crypto.SHA384, 10: crypto.SHA512}

// verifyDetachedSignature checks sigData (armored or binary) over data and
// returns the key that made a valid signature. A signature file may carry
// several signatures; one valid signature by a trusted key is enough.
func verifyDetachedSignature(data, sigData []byte, keys []pgpKey) (pgpKey, error) {
	raw, err := dearmor(sigData)
	if err != nil {
		return pgpKey{}, err
	}
	packets, err := readPackets(raw)
	if err != nil {
		return pgpKey{}, err
	}
	lastErr := errors.New("no OpenPGP signature found")
	for _, p := range packets {
		if p.tag != 2 {
			continue
		}
		key, err := verifySignaturePacket(data, p.body, keys)
		if err == nil {
			return key, nil
		}
		lastErr = err
	}
	return pgpKey{}, lastErr
}

func verifySignaturePacket(data, sig []byte, keys []pgpKey) (pgpKey, error) {
	if len(sig) < 6 || sig[0] != 4 {
		return pgpKey{}, errors.New("only v4 OpenPGP signatures are supported")
	}
	if sig[1] != 0x00 {
		return pgpKey{}, fmt.Errorf("unsupported signature type 0x%02x (want binary document, 0x00)", sig[1])
	}
	if sig[2] != 1 && sig[2] != 3 {
		return pgpKey{}, fmt.Errorf("unsupported public-key algorithm %d (want RSA)", sig[2])
	}
	hash, ok := pgpHashes[sig[3]]
	if !ok {
		return pgpKey{}, fmt.Errorf("unsupported hash algorithm %d", sig[3])
	}

	hashedEnd := 6 + int(binary.BigEndian.Uint16(sig[4:6]))
	if len(sig) < hashedEnd+2 {
		return pgpKey{}, errTruncated
	}
	unhashedEnd := hashedEnd + 2 + int(binary.BigEndian.Uint16(sig[hashedEnd:hashedEnd+2]))
	if len(sig) < unhashedEnd+2 {
		return pgpKey{}, errTruncated
	}
	left16 := sig[unhashedEnd : unhashedEnd+2]
	sigMPI, _, err := readMPI(sig[unhashedEnd+2:])
	if err != nil {
		return pgpKey{}, err
	}

	// RFC 4880 5.2.4: document, then the signature's own version..hashed
	// subpackets, then a trailer carrying that hashed portion's length.
	h := hash.New()
	h.Write(data)
	h.Write(sig[:hashedEnd])
	trailer := []byte{4, 0xff, 0, 0, 0, 0}
	binary.BigEndian.PutUint32(trailer[2:], uint32(hashedEnd))
	h.Write(trailer)
	digest := h.Sum(nil)
	if !bytes.Equal(digest[:2], left16) {
		return pgpKey{}, errors.New("signature does not match the signed data")
	}

	// Trying every trusted key instead of trusting the (possibly unhashed)
	// issuer subpacket: there are only a handful, and a wrong issuer claim
	// can't make a signature verify against the wrong key anyway.
	for _, key := range keys {
		k := key.pub.Size()
		if len(sigMPI) > k {
			continue
		}
		padded := make([]byte, k)
		copy(padded[k-len(sigMPI):], sigMPI)
		if rsa.VerifyPKCS1v15(key.pub, hash, digest, padded) == nil {
			return key, nil
		}
	}
	return pgpKey{}, errors.New("not signed by any trusted key")
}
