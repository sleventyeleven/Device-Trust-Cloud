package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writePair(t *testing.T, certFile, keyFile, cn string, mod time.Time) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: cn},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{certFile, keyFile} {
		if err := os.Chtimes(f, mod, mod); err != nil {
			t.Fatal(err)
		}
	}
}

func cnOf(t *testing.T, r *keyPairReloader) string {
	t.Helper()
	c, err := r.GetCertificate(nil)
	if err != nil {
		t.Fatalf("GetCertificate: %v", err)
	}
	leaf, err := x509.ParseCertificate(c.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	return leaf.Subject.CommonName
}

func TestKeyPairReloaderPicksUpRenewedCertificate(t *testing.T) {
	dir := t.TempDir()
	certFile, keyFile := filepath.Join(dir, "tls.crt"), filepath.Join(dir, "tls.key")
	base := time.Now().Add(-time.Hour)
	writePair(t, certFile, keyFile, "first", base)

	r, err := newKeyPairReloader(certFile, keyFile)
	if err != nil {
		t.Fatal(err)
	}
	if got := cnOf(t, r); got != "first" {
		t.Fatalf("CN = %q", got)
	}

	writePair(t, certFile, keyFile, "second", base.Add(time.Minute)) // a renewal
	if got := cnOf(t, r); got != "second" {
		t.Errorf("renewed certificate not picked up: CN = %q", got)
	}

	// A renewal caught half-written (key and certificate disagree) must not take
	// the server down: it keeps serving the last good pair.
	writePair(t, certFile, keyFile, "third", base.Add(2*time.Minute))
	other := filepath.Join(dir, "other.key")
	writePair(t, filepath.Join(dir, "other.crt"), other, "x", base.Add(2*time.Minute))
	b, _ := os.ReadFile(other)
	os.WriteFile(keyFile, b, 0o600)
	os.Chtimes(keyFile, base.Add(3*time.Minute), base.Add(3*time.Minute))
	if got := cnOf(t, r); got != "second" {
		t.Errorf("a mismatched pair replaced the good one: CN = %q", got)
	}
}

func TestKeyPairReloaderNeedsAValidPairAtStartup(t *testing.T) {
	dir := t.TempDir()
	if _, err := newKeyPairReloader(filepath.Join(dir, "a.crt"), filepath.Join(dir, "a.key")); err == nil {
		t.Error("missing files accepted")
	}
	c, k := filepath.Join(dir, "b.crt"), filepath.Join(dir, "b.key")
	os.WriteFile(c, []byte("not a cert"), 0o600)
	os.WriteFile(k, []byte("not a key"), 0o600)
	if _, err := newKeyPairReloader(c, k); err == nil {
		t.Error("garbage accepted")
	}
}
