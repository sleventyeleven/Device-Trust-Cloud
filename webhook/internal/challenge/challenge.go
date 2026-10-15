// Package challenge implements the per-device SCEP challenge shared by the
// webhook server and the client-side enrollment scripts.
//
//	challenge = base64( HMAC-SHA256( key = phrase, message = Context + "\n" + id ) )
//
// where id is the device's serial number (or hostname) after normalisation (see
// NormalizeSerial) and base64 is the standard alphabet with padding.
//
// The phrase is the shared, short-lived secret; the serial number or hostname is
// public. HMAC is used rather than encrypting the phrase because it is one-way:
// a challenge that leaks does not reveal the phrase.
//
// Any client implementation must reproduce this byte for byte. The known-answer
// tests were cross-checked against OpenSSL and PowerShell (.NET); the README has
// copy-paste snippets for both.
package challenge

import (
	"bufio"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"math/big"
	"strings"
)

// Context domain-separates this construction and carries its version.
const Context = "device-trust-scep-challenge-v1"

const (
	// MaxIDLen bounds the normalised serial number / hostname length.
	MaxIDLen = 64
	// MaxPhraseLen bounds the phrase length.
	MaxPhraseLen = 128
	// MinWordlist is the smallest word list Generate will draw from.
	MinWordlist = 256
)

// NormalizeSerial returns the canonical form of a device serial number or
// hostname: surrounding ASCII whitespace removed, then upper-cased. The result
// must be 1 to MaxIDLen printable ASCII characters. Restricting to ASCII keeps
// upper-casing identical on every platform, so bash, PowerShell and Go can never
// disagree.
func NormalizeSerial(raw string) (string, error) {
	s := strings.Trim(raw, " \t\r\n")
	if s == "" {
		return "", errors.New("serial number or hostname is empty")
	}
	if len(s) > MaxIDLen {
		return "", fmt.Errorf("serial number or hostname is longer than %d characters", MaxIDLen)
	}
	for i := 0; i < len(s); i++ {
		if c := s[i]; c < 0x20 || c > 0x7e {
			return "", fmt.Errorf("serial number or hostname has a non-printable or non-ASCII character at byte %d", i)
		}
	}
	return strings.ToUpper(s), nil
}

// ValidatePhrase checks that a phrase is usable: printable ASCII with no spaces
// (so it survives being passed on a command line) and at most MaxPhraseLen long.
// It never includes the phrase in an error message.
func ValidatePhrase(phrase string) error {
	if phrase == "" {
		return errors.New("phrase is empty")
	}
	if len(phrase) > MaxPhraseLen {
		return fmt.Errorf("phrase is longer than %d characters", MaxPhraseLen)
	}
	for i := 0; i < len(phrase); i++ {
		if c := phrase[i]; c <= 0x20 || c > 0x7e {
			return errors.New("phrase must be printable ASCII with no spaces (use hyphens between words)")
		}
	}
	return nil
}

// Compute returns the SCEP challenge for a device serial number or hostname
// under a phrase. The id is normalised first, so callers may pass it as read
// from the device. The phrase is used exactly as given.
func Compute(phrase, id string) (string, error) {
	if phrase == "" {
		return "", errors.New("phrase is empty")
	}
	s, err := NormalizeSerial(id)
	if err != nil {
		return "", err
	}
	mac := hmac.New(sha256.New, []byte(phrase))
	mac.Write([]byte(Context + "\n" + s))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil)), nil
}

// ParseWordlist reads a word list with one word per line. Blank lines and lines
// starting with '#' are skipped, and if a line has several whitespace-separated
// fields the last is the word, so EFF/diceware files ("11111  abacus") work
// unchanged. Duplicates are dropped.
func ParseWordlist(r io.Reader) ([]string, error) {
	var words []string
	seen := map[string]bool{}
	sc := bufio.NewScanner(r)
	for n := 1; sc.Scan(); n++ {
		f := strings.Fields(sc.Text())
		if len(f) == 0 || strings.HasPrefix(f[0], "#") {
			continue
		}
		w := f[len(f)-1]
		if err := ValidatePhrase(w); err != nil {
			return nil, fmt.Errorf("word list line %d: %w", n, err)
		}
		if !seen[w] {
			seen[w] = true
			words = append(words, w)
		}
	}
	return words, sc.Err()
}

// Generate returns a phrase of n words chosen uniformly at random (crypto/rand)
// from words and joined with hyphens, e.g. "Queen-Ate-Lamp-Wise-Smell".
func Generate(words []string, n int) (string, error) {
	if len(words) < MinWordlist {
		return "", fmt.Errorf("word list has %d words; at least %d are needed for a phrase worth using", len(words), MinWordlist)
	}
	if n < 1 {
		return "", errors.New("a phrase needs at least one word")
	}
	picked := make([]string, n)
	max := big.NewInt(int64(len(words)))
	for i := range picked {
		k, err := rand.Int(rand.Reader, max)
		if err != nil {
			return "", err
		}
		picked[i] = words[k.Int64()]
	}
	p := strings.Join(picked, "-")
	return p, ValidatePhrase(p)
}
