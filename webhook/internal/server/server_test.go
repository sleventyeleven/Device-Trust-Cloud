package server

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/allowlist"
	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/challenge"
	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/store"
)

const (
	phrase = "Queen-Ate-Lamp-Wise-Smell"
	// Signing secrets as step-ca prints them: base64 of random bytes.
	enrollSecret = "c2lnbmluZy1zZWNyZXQtZm9yLXRlc3RzLW9ubHk="
	renewSecret  = "cmVuZXctc2lnbmluZy1zZWNyZXQtZm9yLXRlc3Rz"

	enrollProv = "device-enroll"
	renewProv  = "device-renew"

	// Hostname (CN and SAN) in testdata/step_ca_scep_request.json; the CSR carries
	// no serial number, the allowlist maps the hostname to this one.
	fixtureHost   = "CORSAIRAI"
	fixtureSerial = "ABC123XYZ"
)

var now = time.Date(2026, 10, 9, 12, 0, 30, 0, time.UTC)

// Two different public keys (PKIX DER, base64 as it appears in the request).
var (
	keyA string // the fixture's own key
	keyB = base64.StdEncoding.EncodeToString([]byte("a different public key"))
)

type env struct {
	h      *Handler
	store  *store.Store
	body   map[string]any // decoded fixture; tests modify it, then call do
	secret string
}

func newEnv(t *testing.T, mod func(*Config)) *env {
	t.Helper()
	dir := t.TempDir()
	st, err := store.Open(filepath.Join(dir, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	if _, err := st.AddPhrase(context.Background(), phrase, now.Add(-time.Hour), now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	devices := filepath.Join(dir, "devices.csv")
	if err := os.WriteFile(devices, []byte("# fleet\n"+fixtureHost+","+fixtureSerial+",fixture\nOTHERHOST,OTHER1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	l, err := allowlist.Load(devices)
	if err != nil {
		t.Fatal(err)
	}

	cfg := Config{
		Allowlist:         l,
		State:             st,
		SigningSecrets:    []string{enrollSecret, renewSecret},
		EnrollProvisioner: enrollProv,
		RenewProvisioner:  renewProv,
		Now:               func() time.Time { return now },
		Logger:            slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	if mod != nil {
		mod(&cfg)
	}
	h, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(filepath.Join("..", "..", "testdata", "step_ca_scep_request.json"))
	if err != nil {
		t.Fatal(err)
	}
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatal(err)
	}
	e := &env{h: h, store: st, body: body, secret: enrollSecret}
	keyA = e.csr()["publicKey"].(string)
	e.body["provisionerName"] = enrollProv
	return e
}

func sign(secret string, body []byte) string {
	key, _ := base64.StdEncoding.DecodeString(secret)
	m := hmac.New(sha256.New, key)
	m.Write(body)
	return hex.EncodeToString(m.Sum(nil))
}

func (e *env) do(t *testing.T) *httptest.ResponseRecorder {
	t.Helper()
	b, err := json.Marshal(e.body)
	if err != nil {
		t.Fatal(err)
	}
	return e.doRaw(b, sign(e.secret, b))
}

func (e *env) doRaw(body []byte, sig string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, ChallengePath, bytes.NewReader(body))
	r.Header.Set("X-Smallstep-Signature", sig)
	w := httptest.NewRecorder()
	e.h.ServeHTTP(w, r)
	return w
}

// enroll and renew switch the request to the given provisioner (and its secret).
func (e *env) asEnroll() { e.body["provisionerName"], e.secret = enrollProv, enrollSecret }
func (e *env) asRenew()  { e.body["provisionerName"], e.secret = renewProv, renewSecret }

// setChallenge puts the challenge a device with this serial number would send
// under the given phrase into the request.
func (e *env) setChallenge(t *testing.T, p, serial string) {
	t.Helper()
	c, err := challenge.Compute(p, serial)
	if err != nil {
		t.Fatal(err)
	}
	e.body["scepChallenge"] = c
}

func (e *env) csr() map[string]any { return e.body["x509CertificateRequest"].(map[string]any) }

func (e *env) setCN(cn string)  { e.csr()["subject"].(map[string]any)["commonName"] = cn }
func (e *env) setKey(k string)  { e.csr()["publicKey"] = k }
func (e *env) setHost(h string) { e.setCN(h); e.setSANs(san2(h)) }
func (e *env) setSANs(exts ...[]byte) {
	var list []any
	for _, der := range exts {
		list = append(list, map[string]any{"id": oidSubjectAltName, "critical": false, "value": base64.StdEncoding.EncodeToString(der)})
	}
	e.csr()["extensions"] = list
}

// gn is a general name for a SAN extension (tag 1 email, 2 DNS, 7 IP).
type gn struct {
	tag int
	val string
}

func sanDER(names ...gn) []byte {
	var inner []byte
	for _, n := range names {
		b, err := asn1.Marshal(asn1.RawValue{Class: asn1.ClassContextSpecific, Tag: n.tag, Bytes: []byte(n.val)})
		if err != nil {
			panic(err)
		}
		inner = append(inner, b...)
	}
	der, err := asn1.Marshal(asn1.RawValue{Class: asn1.ClassUniversal, Tag: asn1.TagSequence, IsCompound: true, Bytes: inner})
	if err != nil {
		panic(err)
	}
	return der
}

func san2(dns string) []byte { return sanDER(gn{2, dns}) }

func wantAllow(t *testing.T, w *httptest.ResponseRecorder, want bool) {
	t.Helper()
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, body %q; want 200", w.Code, w.Body.String())
	}
	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("response is not JSON: %v (%q)", err, w.Body.String())
	}
	if len(resp) != 1 || resp["allow"] != want {
		t.Errorf("response = %v, want {allow: %v}", resp, want)
	}
}

// enrolled returns an env where the fixture host has already enrolled with keyA.
func enrolled(t *testing.T, mod func(*Config)) *env {
	t.Helper()
	e := newEnv(t, mod)
	e.setChallenge(t, phrase, fixtureSerial)
	wantAllow(t, e.do(t), true)
	return e
}

func TestFixtureIsWhatWeThink(t *testing.T) {
	e := newEnv(t, nil)
	b, _ := json.Marshal(e.body)
	var r requestBody
	if err := json.Unmarshal(b, &r); err != nil {
		t.Fatal(err)
	}
	host, err := identify(&r)
	if err != nil || host != fixtureHost || len(r.X509CertificateRequest.PublicKey) == 0 {
		t.Fatalf("identify(fixture) = %q, %v (key bytes %d)", host, err, len(r.X509CertificateRequest.PublicKey))
	}
}

// --- enrollment ------------------------------------------------------------

func TestEnrollAllowsChallengeDerivedFromTheMappedSerial(t *testing.T) {
	e := newEnv(t, nil)
	e.setChallenge(t, phrase, strings.ToLower(fixtureSerial)) // script did not upper-case
	e.setCN("corsairai")
	wantAllow(t, e.do(t), true)

	pin, ok, _ := e.store.PinFor(context.Background(), fixtureHost)
	if !ok || base64.StdEncoding.EncodeToString(pin) != keyA {
		t.Errorf("enrollment did not pin the CSR's key (pinned %v)", ok)
	}
}

func TestEnrollDenies(t *testing.T) {
	tests := []struct {
		name  string
		setup func(t *testing.T, e *env)
	}{
		{"the static challenge from the fixture", func(t *testing.T, e *env) {}},
		{"empty challenge", func(t *testing.T, e *env) { e.body["scepChallenge"] = "" }},
		{"wrong phrase", func(t *testing.T, e *env) { e.setChallenge(t, "Queen-Ate-Lamp-Wise-Smelt", fixtureSerial) }},
		{"challenge computed from another host's serial", func(t *testing.T, e *env) { e.setChallenge(t, phrase, "OTHER1") }},
		{"challenge computed from the hostname instead of the serial", func(t *testing.T, e *env) { e.setChallenge(t, phrase, fixtureHost) }},
		{"hostname not on the allowlist", func(t *testing.T, e *env) {
			e.setHost("STRANGER")
			e.setChallenge(t, phrase, fixtureSerial)
		}},
		{"phrase revoked", func(t *testing.T, e *env) {
			ps, _ := e.store.ListPhrases(context.Background())
			if err := e.store.RevokePhrase(context.Background(), ps[0].ID, now); err != nil {
				t.Fatal(err)
			}
			e.setChallenge(t, phrase, fixtureSerial)
		}},
		{"phrase expired", func(t *testing.T, e *env) {
			e.h.cfg.Now = func() time.Time { return now.Add(2 * time.Hour) }
			e.setChallenge(t, phrase, fixtureSerial)
		}},
		{"no name at all", func(t *testing.T, e *env) {
			e.setCN("")
			e.setSANs()
			e.setChallenge(t, phrase, fixtureSerial)
		}},
		{"unusable common name", func(t *testing.T, e *env) {
			e.setCN("bad\x01name")
			e.setChallenge(t, phrase, fixtureSerial)
		}},
		{"no public key", func(t *testing.T, e *env) {
			delete(e.csr(), "publicKey")
			e.setChallenge(t, phrase, fixtureSerial)
		}},
		{"no CSR at all", func(t *testing.T, e *env) {
			delete(e.body, "x509CertificateRequest")
			e.setChallenge(t, phrase, fixtureSerial)
		}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv(t, nil)
			tc.setup(t, e)
			wantAllow(t, e.do(t), false)
			if _, ok, _ := e.store.PinFor(context.Background(), fixtureHost); ok {
				t.Error("a refused enrollment pinned a key")
			}
		})
	}
}

func TestSANsMustBeTheHostname(t *testing.T) {
	cases := []struct {
		name  string
		setup func(e *env)
		want  bool
	}{
		{"no SAN extension", func(e *env) { e.setSANs() }, true},
		{"SAN equals hostname", func(e *env) { e.setSANs(san2("corsairai")) }, true},
		{"SAN is an FQDN of the host", func(e *env) { e.setSANs(sanDER(gn{2, "corsairai"}, gn{2, "corsairai.corp.example.com"})) }, true},
		{"CN empty, SAN gives the hostname", func(e *env) { e.setCN(""); e.setSANs(san2("CORSAIRAI")) }, true},
		{"SAN names another host", func(e *env) { e.setSANs(sanDER(gn{2, "CORSAIRAI"}, gn{2, "OTHERHOST"})) }, false},
		{"SAN only looks like a subdomain", func(e *env) { e.setSANs(san2("CORSAIRAI-evil.example.com")) }, false},
		{"SAN with an email", func(e *env) { e.setSANs(sanDER(gn{2, "CORSAIRAI"}, gn{1, "ceo@example.com"})) }, false},
		{"SAN with an IP", func(e *env) { e.setSANs(sanDER(gn{2, "CORSAIRAI"}, gn{7, "\x0a\x00\x00\x01"})) }, false},
		{"two SAN extensions", func(e *env) { e.setSANs(san2("CORSAIRAI"), san2("OTHERHOST")) }, false},
		{"garbage SAN extension", func(e *env) { e.setSANs([]byte("not asn1")) }, false},
		{"trailing bytes after the SAN", func(e *env) { e.setSANs(append(san2("CORSAIRAI"), 0)) }, false},
	}
	for _, tc := range cases {
		t.Run("enroll/"+tc.name, func(t *testing.T) {
			e := newEnv(t, nil)
			tc.setup(e)
			e.setChallenge(t, phrase, fixtureSerial)
			wantAllow(t, e.do(t), tc.want)
		})
		t.Run("renew/"+tc.name, func(t *testing.T) {
			e := enrolled(t, nil)
			e.asRenew()
			tc.setup(e)
			wantAllow(t, e.do(t), tc.want)
		})
	}
}

func TestRotationOverlap(t *testing.T) {
	// Two phrases are active at once while one is replaced by the next.
	e := newEnv(t, nil)
	if _, err := e.store.AddPhrase(context.Background(), "one-two-three-four-five", now, now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	e.setChallenge(t, "one-two-three-four-five", fixtureSerial)
	wantAllow(t, e.do(t), true)
}

func TestEnrollIsSingleUse(t *testing.T) {
	e := newEnv(t, nil)
	e.setChallenge(t, phrase, fixtureSerial)

	e.body["scepTransactionID"] = "txn-A"
	wantAllow(t, e.do(t), true)
	wantAllow(t, e.do(t), true) // the client retrying the same enrollment
	e.body["scepTransactionID"] = "txn-B"
	wantAllow(t, e.do(t), false) // a second enrollment with the same phrase

	// Another host can still use the same phrase.
	e.setHost("OTHERHOST")
	e.setChallenge(t, phrase, "OTHER1")
	wantAllow(t, e.do(t), true)

	// A new phrase lets the first host enroll again, with a new key.
	if _, err := e.store.AddPhrase(context.Background(), "one-two-three-four-five", now, now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	e.setHost(fixtureHost)
	e.setKey(keyB)
	e.setChallenge(t, "one-two-three-four-five", fixtureSerial)
	e.body["scepTransactionID"] = "txn-C"
	wantAllow(t, e.do(t), true)
	if pin, _, _ := e.store.PinFor(context.Background(), fixtureHost); base64.StdEncoding.EncodeToString(pin) != keyB {
		t.Error("re-enrollment did not replace the pin")
	}

	// A refused enrollment must not change the pin (keyA tries the used phrase).
	e.setKey(keyA)
	e.setChallenge(t, phrase, fixtureSerial)
	e.body["scepTransactionID"] = "txn-D"
	wantAllow(t, e.do(t), false)
	if pin, _, _ := e.store.PinFor(context.Background(), fixtureHost); base64.StdEncoding.EncodeToString(pin) != keyB {
		t.Error("a refused enrollment changed the pin")
	}

	// An admin can reset a host whose issuance failed after the webhook allowed it.
	if n, err := e.store.ResetUses(context.Background(), fixtureHost); err != nil || n != 2 {
		t.Fatalf("ResetUses = %d, %v", n, err)
	}
	wantAllow(t, e.do(t), true)
}

// --- renewal ---------------------------------------------------------------

func TestRenewNeedsNoPhraseButTheEnrolledKey(t *testing.T) {
	e := enrolled(t, nil)
	e.asRenew()
	e.body["scepChallenge"] = "" // nothing to send: there is no phrase on this path
	wantAllow(t, e.do(t), true)

	// Whatever challenge a client sends is ignored.
	e.body["scepChallenge"] = "anything"
	wantAllow(t, e.do(t), true)

	// ...but the key must be the enrolled one.
	e.setKey(keyB)
	wantAllow(t, e.do(t), false)
}

func TestRenewDenies(t *testing.T) {
	t.Run("host never enrolled", func(t *testing.T) {
		e := newEnv(t, nil)
		e.asRenew()
		wantAllow(t, e.do(t), false)
	})
	t.Run("another host's key", func(t *testing.T) {
		e := enrolled(t, nil)
		// OTHERHOST enrolls with keyB, then tries to renew as CORSAIRAI with it.
		e.asEnroll()
		e.setHost("OTHERHOST")
		e.setKey(keyB)
		e.setChallenge(t, phrase, "OTHER1")
		wantAllow(t, e.do(t), true)
		e.asRenew()
		e.setHost(fixtureHost)
		wantAllow(t, e.do(t), false)
	})
	t.Run("removed from the allowlist", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "devices.csv")
		os.WriteFile(path, []byte(fixtureHost+","+fixtureSerial+"\n"), 0o600)
		l, err := allowlist.Load(path)
		if err != nil {
			t.Fatal(err)
		}
		e := enrolled(t, func(c *Config) { c.Allowlist = l })
		e.asRenew()
		wantAllow(t, e.do(t), true)

		os.WriteFile(path, []byte("OTHERHOST,OTHER1\n"), 0o600) // decommissioned
		os.Chtimes(path, now.Add(time.Hour), now.Add(time.Hour))
		wantAllow(t, e.do(t), false)
	})
	t.Run("pin cleared", func(t *testing.T) {
		e := enrolled(t, nil)
		e.asRenew()
		if ok, err := e.store.ClearPin(context.Background(), fixtureHost); err != nil || !ok {
			t.Fatal(err)
		}
		wantAllow(t, e.do(t), false)
	})
	t.Run("no public key", func(t *testing.T) {
		e := enrolled(t, nil)
		e.asRenew()
		delete(e.csr(), "publicKey")
		wantAllow(t, e.do(t), false)
	})
}

func TestRenewKeepsWorkingAfterThePhraseIsGone(t *testing.T) {
	e := enrolled(t, nil)
	ps, _ := e.store.ListPhrases(context.Background())
	if err := e.store.RevokePhrase(context.Background(), ps[0].ID, now); err != nil {
		t.Fatal(err)
	}
	e.h.cfg.Now = func() time.Time { return now.Add(90 * 24 * time.Hour) }
	e.asRenew()
	wantAllow(t, e.do(t), true)
}

// --- provisioners, signatures, config --------------------------------------

func TestProvisionerSelection(t *testing.T) {
	e := newEnv(t, nil)
	e.setChallenge(t, phrase, fixtureSerial)

	e.body["provisionerName"] = "device-trust-scep" // the fixture's own name: not served
	wantAllow(t, e.do(t), false)
	e.body["provisionerName"] = ""
	wantAllow(t, e.do(t), false)

	// A server configured for only one provisioner refuses the other.
	only := newEnv(t, func(c *Config) { c.RenewProvisioner = "" })
	only.setChallenge(t, phrase, fixtureSerial)
	wantAllow(t, only.do(t), true)
	only.body["provisionerName"] = renewProv
	wantAllow(t, only.do(t), false)
}

func TestSignature(t *testing.T) {
	e := newEnv(t, nil)
	e.setChallenge(t, phrase, fixtureSerial)
	b, _ := json.Marshal(e.body)

	for name, tc := range map[string]struct {
		body []byte
		sig  string
		want int
	}{
		"signed with the enroll secret": {b, sign(enrollSecret, b), http.StatusOK},
		"signed with the renew secret":  {b, sign(renewSecret, b), http.StatusOK},
		"signed with an unknown secret": {b, sign("b3RoZXItc2VjcmV0", b), http.StatusUnauthorized},
		"missing signature":             {b, "", http.StatusUnauthorized},
		"non-hex signature":             {b, "zz", http.StatusUnauthorized},
		"signature of other body":       {b, sign(enrollSecret, []byte("{}")), http.StatusUnauthorized},
		"tampered body":                 {bytes.Replace(b, []byte(fixtureHost), []byte("OTHERHOST"), 1), sign(enrollSecret, b), http.StatusUnauthorized},
		"signed garbage":                {[]byte("not json"), sign(enrollSecret, []byte("not json")), http.StatusBadRequest},
		"oversized":                     {bytes.Repeat([]byte("a"), maxBody+10), sign(enrollSecret, b), http.StatusBadRequest},
	} {
		t.Run(name, func(t *testing.T) {
			e2 := newEnv(t, nil) // fresh store: the enrollment above must not affect the next case
			w := e2.doRaw(tc.body, tc.sig)
			if w.Code != tc.want {
				t.Fatalf("status = %d (%q), want %d", w.Code, w.Body.String(), tc.want)
			}
			if tc.want != http.StatusOK && strings.Contains(w.Body.String(), "allow") {
				t.Errorf("error response looks like a decision: %q", w.Body.String())
			}
		})
	}

	w := httptest.NewRecorder()
	e.h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, ChallengePath, nil))
	if w.Code != http.StatusMethodNotAllowed {
		t.Errorf("GET status = %d", w.Code)
	}
	w = httptest.NewRecorder()
	e.h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, HealthPath, nil))
	if w.Code != http.StatusOK {
		t.Errorf("health status = %d", w.Code)
	}
}

func TestEmptyKeySignatureOnlyWhenAllowed(t *testing.T) {
	// A step-ca configured through a static ca.json has no signing secret and
	// signs with an empty key.

	for _, allow := range []bool{false, true} {
		e := newEnv(t, func(c *Config) { c.AllowEmptySecret = allow })
		e.setChallenge(t, phrase, fixtureSerial)
		b, _ := json.Marshal(e.body)
		m := hmac.New(sha256.New, nil)
		m.Write(b)
		w := e.doRaw(b, hex.EncodeToString(m.Sum(nil)))
		if allow {
			wantAllow(t, w, true)
		} else if w.Code != http.StatusUnauthorized {
			t.Errorf("empty-key signature accepted without AllowEmptySecret: status %d", w.Code)
		}
	}

	// With only the empty secret configured the server needs no real secret.
	c := Config{Allowlist: fakeList{}, State: &store.Store{}, EnrollProvisioner: "a", AllowEmptySecret: true}
	if _, err := New(c); err != nil {
		t.Errorf("empty-secret-only config: %v", err)
	}
}

type fakeList struct{}

func (fakeList) Lookup(string) (allowlist.Device, bool, error) { return allowlist.Device{}, false, nil }

func TestNewValidation(t *testing.T) {
	ok := Config{Allowlist: fakeList{}, State: &store.Store{}, SigningSecrets: []string{enrollSecret},
		EnrollProvisioner: "a", RenewProvisioner: "b"}
	if _, err := New(ok); err != nil {
		t.Fatalf("valid config: %v", err)
	}
	for name, mod := range map[string]func(*Config){
		"no allowlist":     func(c *Config) { c.Allowlist = nil },
		"no state":         func(c *Config) { c.State = nil },
		"no secrets":       func(c *Config) { c.SigningSecrets = nil },
		"secret not b64":   func(c *Config) { c.SigningSecrets = []string{"%%%"} },
		"no provisioners":  func(c *Config) { c.EnrollProvisioner, c.RenewProvisioner = "", "" },
		"same provisioner": func(c *Config) { c.RenewProvisioner = "a" },
	} {
		c := ok
		mod(&c)
		if _, err := New(c); err == nil {
			t.Errorf("%s: want error", name)
		}
	}
}

func TestLogsDoNotContainSecrets(t *testing.T) {
	var buf bytes.Buffer
	e := newEnv(t, func(c *Config) { c.Logger = slog.New(slog.NewTextHandler(&buf, nil)) })
	e.setChallenge(t, phrase, fixtureSerial)
	c := e.body["scepChallenge"].(string)
	wantAllow(t, e.do(t), true)
	e.body["scepChallenge"] = "wrong-" + c
	e.body["scepTransactionID"] = "other"
	wantAllow(t, e.do(t), false)

	logs := buf.String()
	if logs == "" {
		t.Fatal("expected log output")
	}
	// The serial number is not logged either: it is half of what an attacker needs.
	for _, secret := range []string{phrase, c, enrollSecret, renewSecret, fixtureSerial, keyA} {
		if strings.Contains(logs, secret) {
			t.Errorf("logs contain a secret: %q", secret)
		}
	}
}
