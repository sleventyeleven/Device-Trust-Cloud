package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/store"
	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/testsecret"
)

// Generated per test run; see the testsecret package.
var (
	cliPhrase = testsecret.Phrase()
	cliSerial = testsecret.Serial()
	cliHost   = testsecret.Hostname()
)

type result struct {
	code        int
	out, errOut string
}

func runCLI(t *testing.T, stdin string, environ map[string]string, args ...string) result {
	t.Helper()
	var out, errOut bytes.Buffer
	code := run(args, env{
		stdout: &out,
		stderr: &errOut,
		stdin:  strings.NewReader(stdin),
		getenv: func(k string) string { return environ[k] },
	})
	return result{code, out.String(), errOut.String()}
}

func TestPhraseCommands(t *testing.T) {
	dir := t.TempDir()
	environ := map[string]string{"DTW_DB": filepath.Join(dir, "cli.db"), "DTW_PHRASE": cliPhrase}

	var wl strings.Builder
	for i := 0; i < 300; i++ {
		fmt.Fprintf(&wl, "%d%d%d%d%d\tw%d\n", i%6+1, i%5+1, i%4+1, i%3+1, i%2+1, i)
	}
	wordlist := filepath.Join(dir, "words.txt")
	os.WriteFile(wordlist, []byte(wl.String()), 0o600)

	t.Run("add", func(t *testing.T) {
		r := runCLI(t, "", environ, "phrase", "add", "-expires-in", "48h")
		if r.code != 0 || !strings.Contains(r.errOut, "stored phrase 1") {
			t.Errorf("%+v", r)
		}
	})
	t.Run("duplicate", func(t *testing.T) {
		if r := runCLI(t, "", environ, "phrase", "add"); r.code != 1 || !strings.Contains(r.errOut, "already exists") {
			t.Errorf("%+v", r)
		}
	})
	t.Run("new prints only the phrase on stdout", func(t *testing.T) {
		r := runCLI(t, "", environ, "phrase", "new", "-wordlist", wordlist, "-words", "4")
		if r.code != 0 {
			t.Fatalf("%+v", r)
		}
		p := strings.TrimSpace(r.out)
		if strings.Count(p, "-") != 3 || strings.ContainsAny(p, " \t") {
			t.Errorf("stdout = %q, want a 4-word phrase and nothing else", r.out)
		}
		if !strings.Contains(r.errOut, "stored phrase 2") {
			t.Errorf("stderr = %q", r.errOut)
		}
		// The printed phrase is the stored one: a challenge from it must work.
		l := runCLI(t, "", map[string]string{"DTW_PHRASE": p}, "challenge", "ABC")
		if l.code != 0 {
			t.Errorf("%+v", l)
		}
	})
	t.Run("new without a word list", func(t *testing.T) {
		if r := runCLI(t, "", environ, "phrase", "new"); r.code != 2 || !strings.Contains(r.errOut, "word list") {
			t.Errorf("%+v", r)
		}
	})
	t.Run("new with a tiny word list", func(t *testing.T) {
		tiny := filepath.Join(dir, "tiny.txt")
		os.WriteFile(tiny, []byte("a\nb\nc\n"), 0o600)
		if r := runCLI(t, "", environ, "phrase", "new", "-wordlist", tiny); r.code != 1 || !strings.Contains(r.errOut, "word list has 3 words") {
			t.Errorf("%+v", r)
		}
	})
	t.Run("list never shows phrases", func(t *testing.T) {
		r := runCLI(t, "", environ, "phrase", "list")
		if r.code != 0 || !strings.Contains(r.out, "active") || strings.Contains(r.out, cliPhrase) {
			t.Errorf("%+v", r)
		}
	})
	t.Run("revoke", func(t *testing.T) {
		if r := runCLI(t, "", environ, "phrase", "revoke", "1"); r.code != 0 {
			t.Errorf("%+v", r)
		}
		if r := runCLI(t, "", environ, "phrase", "list"); !strings.Contains(r.out, "revoked") {
			t.Errorf("%+v", r)
		}
		if r := runCLI(t, "", environ, "phrase", "revoke", "42"); r.code != 1 || !strings.Contains(r.errOut, "not found") {
			t.Errorf("%+v", r)
		}
		if r := runCLI(t, "", environ, "phrase", "revoke", "abc"); r.code != 2 {
			t.Errorf("%+v", r)
		}
	})
}

func TestUses(t *testing.T) {
	db := filepath.Join(t.TempDir(), "uses.db")
	environ := map[string]string{"DTW_DB": db}

	st, err := store.Open(db)
	if err != nil {
		t.Fatal(err)
	}
	ctx, now := context.Background(), time.Now()
	id, _ := st.AddPhrase(ctx, "a-b-c-d-e", now, now.Add(time.Hour))
	st.Enroll(ctx, id, cliHost, "txn-1", []byte("pinned-key"), now)
	st.Close()

	if r := runCLI(t, "", environ, "uses", "list"); r.code != 0 || !strings.Contains(r.out, cliHost) || !strings.Contains(r.out, "txn-1") {
		t.Errorf("list: %+v", r)
	}
	if r := runCLI(t, "", environ, "phrase", "list"); !strings.Contains(r.out, "1\n") {
		t.Errorf("phrase list should show one device used: %+v", r)
	}
	if r := runCLI(t, "", environ, "uses", "reset", strings.ToLower(cliHost)); r.code != 0 || !strings.Contains(r.out, "cleared 1 use(s) for "+cliHost) {
		t.Errorf("reset: %+v", r)
	}
	if r := runCLI(t, "", environ, "uses", "list"); strings.Contains(r.out, cliHost) {
		t.Errorf("use still listed after reset: %+v", r)
	}

	if r := runCLI(t, "", environ, "pins", "list"); r.code != 0 || !strings.Contains(r.out, cliHost) || strings.Contains(r.out, "pinned-key") {
		t.Errorf("pins list should show the host and a fingerprint, never the key: %+v", r)
	}
	if r := runCLI(t, "", environ, "pins", "clear", strings.ToLower(cliHost)); r.code != 0 || !strings.Contains(r.out, cliHost) {
		t.Errorf("pins clear: %+v", r)
	}
	if r := runCLI(t, "", environ, "pins", "clear", strings.ToLower(cliHost)); r.code != 1 || !strings.Contains(r.errOut, "no pinned key") {
		t.Errorf("pins clear (again): %+v", r)
	}
	if r := runCLI(t, "", environ, "pins", "list"); strings.Contains(r.out, cliHost) {
		t.Errorf("pin still listed after clear: %+v", r)
	}
}

func TestChallenge(t *testing.T) {
	want := testsecret.Challenge(cliPhrase, cliSerial)
	env := map[string]string{"DTW_PHRASE": cliPhrase}
	if r := runCLI(t, "", env, "challenge", strings.ToLower(cliSerial)); r.code != 0 || strings.TrimSpace(r.out) != want {
		t.Errorf("env phrase: %+v", r)
	}
	if r := runCLI(t, cliPhrase+"\n", nil, "challenge", "-phrase-file", "-", cliSerial); r.code != 0 || strings.TrimSpace(r.out) != want {
		t.Errorf("stdin phrase: %+v", r)
	}
	if r := runCLI(t, "", nil, "challenge", "ABC"); r.code == 0 || !strings.Contains(r.errOut, "phrase") {
		t.Errorf("no phrase: %+v", r)
	}
}

func TestUsageAndServeRefusals(t *testing.T) {
	if r := runCLI(t, "", nil); r.code != 2 || !strings.Contains(r.errOut, "Usage") {
		t.Errorf("no args: %+v", r)
	}
	if r := runCLI(t, "", nil, "help"); r.code != 0 || !strings.Contains(r.out, "serve") {
		t.Errorf("help: %+v", r)
	}
	for _, args := range [][]string{{"bogus"}, {"phrase", "bogus"}, {"uses", "bogus"}} {
		if r := runCLI(t, "", nil, args...); r.code != 2 {
			t.Errorf("%v: %+v", args, r)
		}
	}

	dir := t.TempDir()
	devices := filepath.Join(dir, "devices.csv")
	os.WriteFile(devices, []byte("ABC,SN1\n"), 0o600)
	base := map[string]string{"DTW_DB": filepath.Join(dir, "s.db"), "DTW_DEVICES": devices, "DTW_SIGNING_SECRETS": "c2VjcmV0"}
	with := func(drop string) map[string]string {
		m := map[string]string{}
		for k, v := range base {
			if k != drop {
				m[k] = v
			}
		}
		return m
	}
	for name, tc := range map[string]struct {
		env  map[string]string
		args []string
		want string
	}{
		"no allowlist":        {with("DTW_DEVICES"), []string{"-insecure-http", "-enroll-provisioner", "e"}, "allowlist is required"},
		"no secret":           {with("DTW_SIGNING_SECRETS"), []string{"-insecure-http", "-enroll-provisioner", "e"}, "signing secret"},
		"plain http refused":  {base, []string{"-enroll-provisioner", "e"}, "https webhook URLs"},
		"cert without key":    {base, []string{"-enroll-provisioner", "e", "-tls-cert", "c.pem"}, "must be given together"},
		"tls and insecure":    {base, []string{"-enroll-provisioner", "e", "-tls-cert", "c.pem", "-tls-key", "k.pem", "-insecure-http"}, "mutually exclusive"},
		"unreadable tls pair": {base, []string{"-enroll-provisioner", "e", "-tls-cert", filepath.Join(dir, "no.pem"), "-tls-key", filepath.Join(dir, "no.key")}, "no.pem"},
		"no provisioner":      {base, []string{"-insecure-http"}, "name the provisioner"},
		"same name for both":  {base, []string{"-insecure-http", "-enroll-provisioner", "x", "-renew-provisioner", "x"}, "must be different"},
		"bad allowlist":       {map[string]string{"DTW_DB": base["DTW_DB"], "DTW_DEVICES": filepath.Join(dir, "nope"), "DTW_SIGNING_SECRETS": "c2VjcmV0"}, []string{"-insecure-http", "-enroll-provisioner", "e"}, "nope"},
	} {
		r := runCLI(t, "", tc.env, append([]string{"serve"}, tc.args...)...)
		if r.code == 0 || !strings.Contains(r.errOut, tc.want) {
			t.Errorf("%s: %+v", name, r)
		}
	}
}
