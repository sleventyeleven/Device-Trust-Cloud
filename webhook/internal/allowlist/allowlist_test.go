package allowlist

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/testsecret"
)

func write(t *testing.T, path, content string, mtime time.Time) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatal(err)
	}
}

// Synthetic devices, generated per test run; see the testsecret package.
var (
	sampleHost   = testsecret.Hostname()
	sampleSerial = testsecret.Serial()
	sample       = "\xef\xbb\xbf# inventory\n" + strings.ToLower(sampleHost) + ", " + strings.ToLower(sampleSerial) +
		" ,Test laptop, with a comma\n" + testsecret.Hostname() + "," + testsecret.Serial() + "\n\n"
)

func TestLookup(t *testing.T) {
	p := filepath.Join(t.TempDir(), "devices.csv")
	write(t, p, sample, time.Now())
	l, err := Load(p)
	if err != nil {
		t.Fatal(err)
	}
	if l.Len() != 2 {
		t.Errorf("Len = %d, want 2", l.Len())
	}

	d, ok, err := l.Lookup(" " + strings.ToLower(sampleHost) + "\r\n")
	if err != nil || !ok {
		t.Fatalf("Lookup = %+v, %v, %v", d, ok, err)
	}
	want := Device{Hostname: sampleHost, Serial: sampleSerial, Note: "Test laptop, with a comma"}
	if d != want {
		t.Errorf("device = %+v, want %+v", d, want)
	}
	for _, id := range []string{sampleSerial, "nope", "", "bad\x01"} { // a serial is not a hostname
		if _, ok, err := l.Lookup(id); ok || err != nil {
			t.Errorf("Lookup(%q) = %v, %v; want not found", id, ok, err)
		}
	}
}

func TestReloadsWhenFileChanges(t *testing.T) {
	p := filepath.Join(t.TempDir(), "devices.csv")
	base := time.Now().Add(-time.Hour)
	write(t, p, "aaa,S1\n", base)
	l, err := Load(p)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := l.Lookup("bbb"); ok {
		t.Fatal("bbb present before edit")
	}

	write(t, p, "aaa,S1\nbbb,S2\n", base.Add(time.Minute))
	if _, ok, err := l.Lookup("bbb"); err != nil || !ok {
		t.Errorf("edit not picked up: %v, %v", ok, err)
	}

	// Same size, new mtime (e.g. a swapped ConfigMap) is also picked up, and a
	// changed serial takes effect.
	write(t, p, "aaa,S9\nbbb,S2\n", base.Add(2*time.Minute))
	if d, _, _ := l.Lookup("aaa"); d.Serial != "S9" {
		t.Errorf("serial change not picked up: %+v", d)
	}

	// A file that has become invalid fails closed instead of serving stale data.
	write(t, p, "aaa,S1\nbad\n", base.Add(3*time.Minute))
	if _, _, err := l.Lookup("aaa"); err == nil {
		t.Error("invalid file: want error")
	}
	os.Remove(p)
	if _, _, err := l.Lookup("aaa"); err == nil {
		t.Error("missing file: want error")
	}
}

func TestLoadErrors(t *testing.T) {
	dir := t.TempDir()
	if _, err := Load(filepath.Join(dir, "missing")); err == nil {
		t.Error("missing file accepted")
	}
	for name, content := range map[string]string{
		"hostname only":      "ok1,S1\njusthost\n",
		"bad hostname":       "host\x01name,S1\n",
		"bad serial":         "host,ser\x01ial\n",
		"empty serial":       "host,\n",
		"duplicate hostname": "AAA,S1\naaa,S2\n",
		"duplicate serial":   "AAA,S1\nBBB,s1\n",
	} {
		p := filepath.Join(dir, strings.ReplaceAll(name, " ", "_"))
		write(t, p, content, time.Now())
		if _, err := Load(p); err == nil {
			t.Errorf("%s: want error", name)
		} else if !strings.Contains(err.Error(), "line") {
			t.Errorf("%s: error should name the line: %v", name, err)
		}
	}
}
