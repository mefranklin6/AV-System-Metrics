package main

import (
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"time"
)

// A pagination cursor is the base64url (unpadded) encoding of
//
//	version (1 byte, = 1) | event_timestamp as Unix microseconds (int64 BE) | event_id (16 bytes)
//
// It identifies the last row of a page in (event_timestamp, event_id) order.
const (
	cursorVersion     = 1
	cursorBinaryLen   = 1 + 8 + 16
	cursorEncodedLen  = (cursorBinaryLen*8 + 5) / 6 // 34 characters
	minCursorUnixMics = -62135596800000000          // 0001-01-01T00:00:00Z
	maxCursorUnixMics = 253402300799999999          // 9999-12-31T23:59:59.999999Z
)

var errInvalidCursor = errors.New("invalid cursor")

var cursorEncoding = base64.RawURLEncoding.Strict()

type pageCursor struct {
	Timestamp time.Time
	EventID   [16]byte
}

func encodeCursor(c pageCursor) string {
	var buf [cursorBinaryLen]byte
	buf[0] = cursorVersion
	binary.BigEndian.PutUint64(buf[1:9], uint64(c.Timestamp.UnixMicro()))
	copy(buf[9:], c.EventID[:])
	return cursorEncoding.EncodeToString(buf[:])
}

func decodeCursor(value string) (pageCursor, error) {
	if len(value) != cursorEncodedLen {
		return pageCursor{}, errInvalidCursor
	}
	raw, err := cursorEncoding.DecodeString(value)
	if err != nil || len(raw) != cursorBinaryLen || raw[0] != cursorVersion {
		return pageCursor{}, errInvalidCursor
	}
	micros := int64(binary.BigEndian.Uint64(raw[1:9]))
	if micros < minCursorUnixMics || micros > maxCursorUnixMics {
		return pageCursor{}, errInvalidCursor
	}
	var c pageCursor
	c.Timestamp = time.UnixMicro(micros).UTC()
	copy(c.EventID[:], raw[9:])
	return c, nil
}

// parseUUID parses the canonical 8-4-4-4-12 hexadecimal UUID form.
func parseUUID(value string) ([16]byte, error) {
	var out [16]byte
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return out, errors.New("invalid uuid")
	}
	compact := value[0:8] + value[9:13] + value[14:18] + value[19:23] + value[24:36]
	if _, err := hex.Decode(out[:], []byte(compact)); err != nil {
		return [16]byte{}, errors.New("invalid uuid")
	}
	return out, nil
}

// formatUUID renders a UUID in canonical lowercase 8-4-4-4-12 form.
func formatUUID(id [16]byte) string {
	var buf [36]byte
	hex.Encode(buf[0:8], id[0:4])
	buf[8] = '-'
	hex.Encode(buf[9:13], id[4:6])
	buf[13] = '-'
	hex.Encode(buf[14:18], id[6:8])
	buf[18] = '-'
	hex.Encode(buf[19:23], id[8:10])
	buf[23] = '-'
	hex.Encode(buf[24:36], id[10:16])
	return string(buf[:])
}
