package main

import (
	"encoding/base64"
	"strings"
	"testing"
	"time"
)

func TestCursorRoundTrip(t *testing.T) {
	id, err := parseUUID("99c70179-fe4e-4d67-974d-5ab820635daa")
	if err != nil {
		t.Fatal(err)
	}
	cases := []time.Time{
		time.Date(2026, 11, 10, 23, 31, 46, 654474000, time.UTC),
		time.Date(1970, 1, 1, 0, 0, 0, 0, time.UTC),
		time.Date(1969, 12, 31, 23, 59, 59, 999999000, time.UTC),
		time.Date(9999, 12, 31, 23, 59, 59, 999999000, time.UTC),
	}
	for _, ts := range cases {
		encoded := encodeCursor(pageCursor{Timestamp: ts, EventID: id})
		if len(encoded) != cursorEncodedLen || strings.ContainsAny(encoded, "+/=") {
			t.Fatalf("encoded cursor %q is not unpadded base64url of length %d", encoded, cursorEncodedLen)
		}
		decoded, err := decodeCursor(encoded)
		if err != nil {
			t.Fatalf("decode %q: %v", encoded, err)
		}
		if !decoded.Timestamp.Equal(ts) || decoded.EventID != id || decoded.Timestamp.Location() != time.UTC {
			t.Fatalf("round trip = %+v, want %s", decoded, ts)
		}
	}
}

func TestCursorRejectsInvalidInput(t *testing.T) {
	valid := encodeCursor(pageCursor{Timestamp: time.Unix(1_800_000_000, 0)})
	raw, _ := base64.RawURLEncoding.DecodeString(valid)

	wrongVersion := append([]byte(nil), raw...)
	wrongVersion[0] = 2
	outOfRange := append([]byte(nil), raw...)
	for i := 1; i < 9; i++ {
		outOfRange[i] = 0x7f
	}
	// Flip unused trailing bits: a non-canonical encoding of the same bytes.
	last := valid[len(valid)-1]
	idx := strings.IndexByte("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_", last)
	nonCanonical := valid[:len(valid)-1] + string("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"[idx^1])

	bad := []string{
		"",
		"abc",
		valid[:len(valid)-1],
		valid + "A",
		strings.Replace(valid, valid[:1], "+", 1),
		base64.URLEncoding.EncodeToString(raw), // padded
		base64.RawURLEncoding.EncodeToString(wrongVersion),
		base64.RawURLEncoding.EncodeToString(outOfRange),
		nonCanonical,
		strings.Repeat("!", cursorEncodedLen),
	}
	for _, value := range bad {
		if _, err := decodeCursor(value); err == nil {
			t.Fatalf("decodeCursor(%q) accepted invalid input", value)
		}
	}
}

func TestUUIDParseFormat(t *testing.T) {
	in := "F5BA6C9F-571C-472C-8D6A-6002F03D8209"
	id, err := parseUUID(in)
	if err != nil {
		t.Fatal(err)
	}
	if got := formatUUID(id); got != strings.ToLower(in) {
		t.Fatalf("formatUUID = %q", got)
	}
	for _, bad := range []string{"", "f5ba6c9f571c472c8d6a6002f03d8209", "f5ba6c9f-571c-472c-8d6a-6002f03d820", "g5ba6c9f-571c-472c-8d6a-6002f03d8209", "f5ba6c9f_571c-472c-8d6a-6002f03d8209"} {
		if _, err := parseUUID(bad); err == nil {
			t.Fatalf("parseUUID(%q) accepted", bad)
		}
	}
}
