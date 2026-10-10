// Package store is the webhook server's local database: the enrollment phrases
// (each with an expiry), which host has used which phrase, and the public key
// each host enrolled with (its "pin"). It is SQLite via the pure-Go
// modernc.org/sqlite driver, so the server builds without cgo.
//
// The phrases are stored in plaintext because the server has to recompute the
// per-device challenge from them; protect the file accordingly. The pins are
// the only record of which key each host enrolled with, so keep the file on a
// persistent volume and back it up: losing it means every host must enroll
// again.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	_ "modernc.org/sqlite" // registers the "sqlite" database/sql driver

	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/challenge"
)

var (
	// ErrNotFound is returned when a phrase does not exist.
	ErrNotFound = errors.New("not found")
	// ErrExists is returned when adding a phrase that already exists.
	ErrExists = errors.New("already exists")
)

const schema = `
CREATE TABLE IF NOT EXISTS phrases (
	id         INTEGER PRIMARY KEY AUTOINCREMENT,
	phrase     TEXT    NOT NULL UNIQUE,
	created_at INTEGER NOT NULL,
	expires_at INTEGER NOT NULL,
	revoked_at INTEGER
);
CREATE TABLE IF NOT EXISTS uses (
	phrase_id INTEGER NOT NULL REFERENCES phrases(id),
	device    TEXT    NOT NULL,
	txn       TEXT    NOT NULL,
	used_at   INTEGER NOT NULL,
	PRIMARY KEY (phrase_id, device)
);
CREATE TABLE IF NOT EXISTS pins (
	host      TEXT    PRIMARY KEY,
	pubkey    BLOB    NOT NULL,
	phrase_id INTEGER NOT NULL,
	set_at    INTEGER NOT NULL
);
`

// Phrase is an enrollment phrase and its lifetime.
type Phrase struct {
	ID        int64
	Phrase    string
	CreatedAt time.Time
	ExpiresAt time.Time
	RevokedAt *time.Time
	Uses      int // hosts that have enrolled with it
}

// Status reports "revoked", "expired" or "active" as of now.
func (p Phrase) Status(now time.Time) string {
	switch {
	case p.RevokedAt != nil:
		return "revoked"
	case !p.ExpiresAt.After(now):
		return "expired"
	default:
		return "active"
	}
}

// Use records that a host used a phrase to enroll.
type Use struct {
	PhraseID int64
	Device   string
	Txn      string
	UsedAt   time.Time
}

// Pin is the public key (PKIX DER) a host enrolled with.
type Pin struct {
	Host     string
	Key      []byte
	PhraseID int64
	SetAt    time.Time
}

// Store is the webhook database.
type Store struct {
	db *sql.DB
}

// Open opens the database at path, creating it (mode 0600) if necessary.
func Open(path string) (*Store, error) {
	if path == "" {
		return nil, errors.New("database path is empty")
	}
	if strings.ContainsAny(path, "?#") {
		return nil, errors.New("database path must not contain '?' or '#'")
	}
	// Create the file ourselves first so it is never world-readable.
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("create database file: %w", err)
	}
	f.Close()

	db, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)")
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("create schema: %w", err)
	}
	return &Store{db: db}, nil
}

// Close releases the database.
func (s *Store) Close() error { return s.db.Close() }

func ts(t time.Time) int64     { return t.Unix() }
func fromTS(v int64) time.Time { return time.Unix(v, 0).UTC() }

// AddPhrase stores a new phrase that expires at expires.
func (s *Store) AddPhrase(ctx context.Context, phrase string, now, expires time.Time) (int64, error) {
	if err := challenge.ValidatePhrase(phrase); err != nil {
		return 0, err
	}
	if !expires.After(now) {
		return 0, errors.New("expiry must be in the future")
	}
	var one int
	err := s.db.QueryRowContext(ctx, `SELECT 1 FROM phrases WHERE phrase = ?`, phrase).Scan(&one)
	switch {
	case err == nil:
		return 0, fmt.Errorf("phrase %w", ErrExists)
	case !errors.Is(err, sql.ErrNoRows):
		return 0, err
	}
	res, err := s.db.ExecContext(ctx,
		`INSERT INTO phrases (phrase, created_at, expires_at) VALUES (?, ?, ?)`,
		phrase, ts(now), ts(expires))
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

const phraseCols = `id, phrase, created_at, expires_at, revoked_at,
	(SELECT COUNT(*) FROM uses WHERE uses.phrase_id = phrases.id)`

func scanPhrases(rows *sql.Rows) ([]Phrase, error) {
	defer rows.Close()
	var out []Phrase
	for rows.Next() {
		var (
			p                Phrase
			created, expires int64
			revoked          sql.NullInt64
		)
		if err := rows.Scan(&p.ID, &p.Phrase, &created, &expires, &revoked, &p.Uses); err != nil {
			return nil, err
		}
		p.CreatedAt, p.ExpiresAt = fromTS(created), fromTS(expires)
		if revoked.Valid {
			t := fromTS(revoked.Int64)
			p.RevokedAt = &t
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// ListPhrases returns every phrase, oldest first.
func (s *Store) ListPhrases(ctx context.Context) ([]Phrase, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT `+phraseCols+` FROM phrases ORDER BY id`)
	if err != nil {
		return nil, err
	}
	return scanPhrases(rows)
}

// ActivePhrases returns the phrases that are neither revoked nor expired at now.
func (s *Store) ActivePhrases(ctx context.Context, now time.Time) ([]Phrase, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT `+phraseCols+` FROM phrases WHERE revoked_at IS NULL AND expires_at > ? ORDER BY id`, ts(now))
	if err != nil {
		return nil, err
	}
	return scanPhrases(rows)
}

// RevokePhrase invalidates a phrase immediately. Revoking twice is not an error.
func (s *Store) RevokePhrase(ctx context.Context, id int64, now time.Time) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE phrases SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`, ts(now), id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n > 0 {
		return nil
	}
	var one int
	if err := s.db.QueryRowContext(ctx, `SELECT 1 FROM phrases WHERE id = ?`, id).Scan(&one); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("phrase %d: %w", id, ErrNotFound)
		}
		return err
	}
	return nil
}

// Enroll consumes a phrase for a host and pins the host's public key, and
// reports whether the caller may go ahead. The first call for a (phrase, host)
// pair succeeds. A later call succeeds only if it carries the same non-empty
// SCEP transaction ID, so a client retrying the same enrollment is not locked
// out by its own first attempt; any other call fails and changes nothing. The
// use and the pin are written together.
func (s *Store) Enroll(ctx context.Context, phraseID int64, host, txn string, pubkey []byte, now time.Time) (bool, error) {
	if len(pubkey) == 0 {
		return false, errors.New("no public key to pin")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`INSERT OR IGNORE INTO uses (phrase_id, device, txn, used_at) VALUES (?, ?, ?, ?)`,
		phraseID, host, txn, ts(now))
	if err != nil {
		return false, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		var prev string
		if err := tx.QueryRowContext(ctx,
			`SELECT txn FROM uses WHERE phrase_id = ? AND device = ?`, phraseID, host).Scan(&prev); err != nil {
			return false, err
		}
		if txn == "" || prev != txn {
			return false, nil
		}
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO pins (host, pubkey, phrase_id, set_at) VALUES (?, ?, ?, ?)
		 ON CONFLICT(host) DO UPDATE SET pubkey = excluded.pubkey, phrase_id = excluded.phrase_id, set_at = excluded.set_at`,
		host, pubkey, phraseID, ts(now)); err != nil {
		return false, err
	}
	return true, tx.Commit()
}

// PinFor returns the public key the host enrolled with.
func (s *Store) PinFor(ctx context.Context, host string) ([]byte, bool, error) {
	var key []byte
	err := s.db.QueryRowContext(ctx, `SELECT pubkey FROM pins WHERE host = ?`, host).Scan(&key)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	return key, err == nil, err
}

// ListPins returns every pin, ordered by host.
func (s *Store) ListPins(ctx context.Context) ([]Pin, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT host, pubkey, phrase_id, set_at FROM pins ORDER BY host`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Pin
	for rows.Next() {
		var (
			p  Pin
			at int64
		)
		if err := rows.Scan(&p.Host, &p.Key, &p.PhraseID, &at); err != nil {
			return nil, err
		}
		p.SetAt = fromTS(at)
		out = append(out, p)
	}
	return out, rows.Err()
}

// ClearPin forgets a host's pinned key, so it must enroll again before it can
// renew. It reports whether there was a pin.
func (s *Store) ClearPin(ctx context.Context, host string) (bool, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM pins WHERE host = ?`, host)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// ListUses returns every recorded use, oldest first.
func (s *Store) ListUses(ctx context.Context) ([]Use, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT phrase_id, device, txn, used_at FROM uses ORDER BY used_at, phrase_id, device`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Use
	for rows.Next() {
		var (
			u  Use
			at int64
		)
		if err := rows.Scan(&u.PhraseID, &u.Device, &u.Txn, &at); err != nil {
			return nil, err
		}
		u.UsedAt = fromTS(at)
		out = append(out, u)
	}
	return out, rows.Err()
}

// ResetUses forgets a host's uses so it can enroll again with a phrase it has
// already used (for example when issuance failed after the webhook allowed it).
func (s *Store) ResetUses(ctx context.Context, host string) (int64, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM uses WHERE device = ?`, host)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}
