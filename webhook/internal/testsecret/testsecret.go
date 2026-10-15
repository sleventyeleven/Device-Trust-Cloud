// Package testsecret makes throwaway secrets for tests.
//
// Nothing secret-shaped is written into the test sources: every phrase and
// signing secret is generated from crypto/rand when the test binary starts, so
// there is nothing for a secret scanner to find and nothing that could be
// mistaken for, or reused as, a real credential. Only test files import this
// package, so it is not part of the webhook binary.
package testsecret

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"math/big"
	"strings"
)

var words = []string{
	"Anchor", "Birch", "Canyon", "Dune", "Ember", "Fjord", "Glacier", "Harbor",
	"Island", "Juniper", "Kettle", "Lagoon", "Meadow", "Nectar", "Orchard", "Pebble",
}

// Phrase returns a random five word, hyphen separated phrase shaped like the
// ones `dtw phrase new` makes.
func Phrase() string {
	parts := make([]string, 5)
	for i := range parts {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(words))))
		if err != nil {
			panic(err)
		}
		parts[i] = words[n.Int64()]
	}
	return strings.Join(parts, "-")
}

// Hostname returns a random, obviously synthetic hostname such as HOST-1A2B3C4D.
func Hostname() string { return randID("HOST-") }

// Serial returns a random, obviously synthetic serial number such as SN1A2B3C4D.
func Serial() string { return randID("SN") }

func randID(prefix string) string {
	b := make([]byte, 4)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return prefix + strings.ToUpper(hex.EncodeToString(b))
}

// Signing returns a random webhook signing secret in the form step-ca prints
// them: base64 of 32 random bytes.
func Signing() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.StdEncoding.EncodeToString(b)
}

// Challenge is an independent implementation of the documented challenge
// formula, base64(HMAC-SHA256(phrase, "device-trust-scep-challenge-v1\n" +
// SERIAL)) with the serial trimmed and upper-cased, written without using the
// challenge package so the tests can compare the two.
func Challenge(phrase, serial string) string {
	m := hmac.New(sha256.New, []byte(phrase))
	m.Write([]byte("device-trust-scep-challenge-v1\n" + strings.ToUpper(strings.Trim(serial, " \t\r\n"))))
	return base64.StdEncoding.EncodeToString(m.Sum(nil))
}
