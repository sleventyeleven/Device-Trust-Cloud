package store

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/testsecret"
)

// Generated per test run; see the testsecret package.
var phrase = testsecret.Phrase()

var t0 = time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)

func open(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestPhraseLifecycle(t *testing.T) {
	ctx := context.Background()
	s := open(t)

	id, err := s.AddPhrase(ctx, phrase, t0, t0.Add(24*time.Hour))
	if err != nil {
		t.Fatalf("AddPhrase: %v", err)
	}
	if _, err := s.AddPhrase(ctx, phrase, t0, t0.Add(time.Hour)); !errors.Is(err, ErrExists) {
		t.Errorf("duplicate phrase: got %v, want ErrExists", err)
	}
	if _, err := s.AddPhrase(ctx, "other-phrase", t0, t0); err == nil {
		t.Error("expiry == now accepted")
	}
	if _, err := s.AddPhrase(ctx, "has space", t0, t0.Add(time.Hour)); err == nil {
		t.Error("phrase with a space accepted")
	}

	active, err := s.ActivePhrases(ctx, t0.Add(time.Hour))
	if err != nil || len(active) != 1 || active[0].Phrase != phrase || active[0].ID != id {
		t.Fatalf("ActivePhrases = %+v, %v", active, err)
	}
	if active, _ := s.ActivePhrases(ctx, t0.Add(24*time.Hour)); len(active) != 0 {
		t.Errorf("phrase still active at its expiry: %+v", active)
	}

	if err := s.RevokePhrase(ctx, id, t0.Add(time.Minute)); err != nil {
		t.Fatalf("RevokePhrase: %v", err)
	}
	if err := s.RevokePhrase(ctx, id, t0.Add(2*time.Minute)); err != nil {
		t.Errorf("revoking twice: %v", err)
	}
	if err := s.RevokePhrase(ctx, 9999, t0); !errors.Is(err, ErrNotFound) {
		t.Errorf("revoke unknown: got %v, want ErrNotFound", err)
	}
	if active, _ := s.ActivePhrases(ctx, t0.Add(time.Hour)); len(active) != 0 {
		t.Errorf("revoked phrase still active: %+v", active)
	}
	list, _ := s.ListPhrases(ctx)
	if len(list) != 1 || list[0].Status(t0.Add(time.Hour)) != "revoked" || !list[0].RevokedAt.Equal(t0.Add(time.Minute)) {
		t.Errorf("ListPhrases = %+v", list)
	}
}

func TestPhraseStatus(t *testing.T) {
	p := Phrase{ExpiresAt: t0.Add(time.Hour)}
	if got := p.Status(t0); got != "active" {
		t.Errorf("got %q", got)
	}
	if got := p.Status(t0.Add(time.Hour)); got != "expired" {
		t.Errorf("got %q", got)
	}
}

func TestEnroll(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	p1, _ := s.AddPhrase(ctx, phrase, t0, t0.Add(time.Hour))
	p2, _ := s.AddPhrase(ctx, "one-two-three-four-five", t0, t0.Add(time.Hour))
	keyA, keyB, keyC := []byte("key-a"), []byte("key-b"), []byte("key-c")

	enroll := func(p int64, host, txn string, key []byte) bool {
		t.Helper()
		ok, err := s.Enroll(ctx, p, host, txn, key, t0)
		if err != nil {
			t.Fatal(err)
		}
		return ok
	}
	pin := func(host string) string {
		t.Helper()
		k, ok, err := s.PinFor(ctx, host)
		if err != nil {
			t.Fatal(err)
		}
		if !ok {
			return "<none>"
		}
		return string(k)
	}

	if pin("ABC") != "<none>" {
		t.Fatal("pin before enrollment")
	}
	if !enroll(p1, "ABC", "txn-1", keyA) || pin("ABC") != "key-a" {
		t.Fatal("first enrollment refused or not pinned")
	}
	if !enroll(p1, "ABC", "txn-1", keyA) {
		t.Error("retry of the same transaction refused")
	}
	if enroll(p1, "ABC", "txn-2", keyB) {
		t.Error("second transaction with the same phrase allowed")
	}
	if pin("ABC") != "key-a" {
		t.Errorf("refused enrollment changed the pin to %q", pin("ABC"))
	}
	if enroll(p1, "ABC", "", keyB) {
		t.Error("second use with no transaction ID allowed")
	}
	if !enroll(p1, "OTHER", "txn-3", keyC) || pin("OTHER") != "key-c" || pin("ABC") != "key-a" {
		t.Error("a different host was affected")
	}
	// A new phrase lets the host enroll again, replacing its pin (new device / new key).
	if !enroll(p2, "ABC", "txn-4", keyB) || pin("ABC") != "key-b" {
		t.Error("re-enrollment with a new phrase did not replace the pin")
	}
	if !enroll(p2, "NOTXN", "", keyA) || enroll(p2, "NOTXN", "", keyA) {
		t.Error("empty transaction IDs must never count as a retry")
	}
	if _, err := s.Enroll(ctx, p1, "X", "t", nil, t0); err == nil {
		t.Error("enrolling with no key accepted")
	}

	uses, err := s.ListUses(ctx)
	if err != nil || len(uses) != 4 {
		t.Fatalf("ListUses = %+v, %v", uses, err)
	}
	if list, _ := s.ListPhrases(ctx); list[0].Uses != 2 || list[1].Uses != 2 {
		t.Errorf("use counts = %d, %d; want 2, 2", list[0].Uses, list[1].Uses)
	}
	if pins, err := s.ListPins(ctx); err != nil || len(pins) != 3 || pins[0].Host != "ABC" {
		t.Errorf("ListPins = %+v, %v", pins, err)
	}

	if n, err := s.ResetUses(ctx, "ABC"); err != nil || n != 2 {
		t.Errorf("ResetUses = %d, %v; want 2", n, err)
	}
	if !enroll(p1, "ABC", "txn-9", keyA) {
		t.Error("host still locked out after reset")
	}

	if ok, err := s.ClearPin(ctx, "ABC"); err != nil || !ok || pin("ABC") != "<none>" {
		t.Errorf("ClearPin = %v, %v", ok, err)
	}
	if ok, _ := s.ClearPin(ctx, "ABC"); ok {
		t.Error("clearing a missing pin reported success")
	}
}

func TestReopenAndBadPaths(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "persist.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := s.AddPhrase(ctx, phrase, t0, t0.Add(time.Hour))
	if ok, err := s.Enroll(ctx, id, "H", "t", []byte("k"), t0); err != nil || !ok {
		t.Fatal(err)
	}
	s.Close()

	s, err = Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer s.Close()
	if active, _ := s.ActivePhrases(ctx, t0); len(active) != 1 {
		t.Errorf("phrase did not persist: %+v", active)
	}
	if k, ok, _ := s.PinFor(ctx, "H"); !ok || string(k) != "k" {
		t.Error("pin did not persist")
	}
	for _, bad := range []string{"", filepath.Join(t.TempDir(), "a?b.db")} {
		if _, err := Open(bad); err == nil {
			t.Errorf("Open(%q) succeeded", bad)
		}
	}
}
