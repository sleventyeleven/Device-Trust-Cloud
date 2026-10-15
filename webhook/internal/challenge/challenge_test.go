package challenge

import (
	"fmt"
	"strings"
	"testing"

	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/testsecret"
)

// Generated per test run; see the testsecret package.
var (
	testPhrase = testsecret.Phrase()
	testSerial = testsecret.Serial()
	testHost   = testsecret.Hostname()
)

// The expected values come from testsecret.Challenge, a separate
// implementation of the documented formula that does not use this package. The
// formula itself (the install scripts use OpenSSL and .NET HMACSHA256 for it)
// is pinned end to end by the deployment tests, where a server only accepts
// what the scripts compute.
var challengeCases = []struct {
	name, id string
}{
	{"typical serial", testSerial},
	{"serial with spaces", "TO BE FILLED BY O.E.M."},
	{"another serial", testsecret.Serial()},
}

func TestComputeMatchesTheDocumentedFormula(t *testing.T) {
	for _, tc := range challengeCases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Compute(testPhrase, tc.id)
			if err != nil {
				t.Fatalf("Compute: %v", err)
			}
			if want := testsecret.Challenge(testPhrase, tc.id); got != want {
				t.Errorf("Compute(%q) = %q, want %q", tc.id, got, want)
			}
		})
	}
}

func TestComputeNormalizesID(t *testing.T) {
	want, _ := Compute(testPhrase, testSerial)
	for _, raw := range []string{strings.ToLower(testSerial), "  " + testSerial, testSerial + "\r\n", "\t" + strings.ToLower(testSerial) + " \n"} {
		got, err := Compute(testPhrase, raw)
		if err != nil || got != want {
			t.Errorf("Compute(%q) = %q, %v; want %q", raw, got, err, want)
		}
	}
}

func TestComputeSeparatesInputs(t *testing.T) {
	base, _ := Compute(testPhrase, testSerial)
	for name, other := range map[string]func() (string, error){
		"serial":      func() (string, error) { return Compute(testPhrase, testSerial+"X") },
		"phrase":      func() (string, error) { return Compute(testPhrase+"x", testSerial) },
		"phrase case": func() (string, error) { return Compute(strings.ToLower(testPhrase), testSerial) },
	} {
		if got, _ := other(); got == base {
			t.Errorf("changing the %s did not change the challenge", name)
		}
	}
}

func TestComputeErrors(t *testing.T) {
	if _, err := Compute("", testSerial); err == nil {
		t.Error("empty phrase: want error")
	}
	if _, err := Compute(testPhrase, "  "); err == nil {
		t.Error("blank id: want error")
	}
}

func TestNormalizeSerial(t *testing.T) {
	ok := map[string]string{
		strings.ToLower(testSerial):                  testSerial,
		"  " + strings.ToLower(testSerial) + " \r\n": testSerial,
		"to be filled by o.e.m.":                     "TO BE FILLED BY O.E.M.",
		strings.ToLower(testHost) + ".example.com":   testHost + ".EXAMPLE.COM",
	}
	for in, want := range ok {
		if got, err := NormalizeSerial(in); err != nil || got != want {
			t.Errorf("NormalizeSerial(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, in := range []string{"", "   ", "abc\x00def", "abc\ndef", "sérial", strings.Repeat("A", MaxIDLen+1)} {
		if got, err := NormalizeSerial(in); err == nil {
			t.Errorf("NormalizeSerial(%q) = %q; want error", in, got)
		}
	}
}

func TestValidatePhrase(t *testing.T) {
	for _, p := range []string{testPhrase, "x", "a-b"} {
		if err := ValidatePhrase(p); err != nil {
			t.Errorf("ValidatePhrase(%q) = %v", p, err)
		}
	}
	for name, p := range map[string]string{
		"empty": "", "space": "two words", "non ascii": "Smëll", "control": "a\x07b", "too long": strings.Repeat("a", MaxPhraseLen+1),
	} {
		err := ValidatePhrase(p)
		if err == nil {
			t.Errorf("%s: want error", name)
		} else if p != "" && strings.Contains(err.Error(), p) {
			t.Errorf("%s: error leaks the phrase: %v", name, err)
		}
	}
}

func wordlist(n int) []string {
	w := make([]string, n)
	for i := range w {
		w[i] = fmt.Sprintf("word%d", i)
	}
	return w
}

func TestParseWordlist(t *testing.T) {
	in := "# eff style\n11111\tabacus\n11112  abdomen\n\nplain\nabacus\n"
	got, err := ParseWordlist(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if want := "abacus abdomen plain"; strings.Join(got, " ") != want {
		t.Errorf("got %v, want %q", got, want)
	}
	if _, err := ParseWordlist(strings.NewReader("ok\nbad\x01word\n")); err == nil || !strings.Contains(err.Error(), "line 2") {
		t.Errorf("want error naming line 2, got %v", err)
	}
}

func TestGenerate(t *testing.T) {
	words := wordlist(MinWordlist)
	seen := map[string]bool{}
	for i := 0; i < 50; i++ {
		p, err := Generate(words, 5)
		if err != nil {
			t.Fatal(err)
		}
		if n := len(strings.Split(p, "-")); n != 5 {
			t.Fatalf("phrase %q has %d words", p, n)
		}
		seen[p] = true
	}
	if len(seen) < 49 { // 256^5 possibilities: a repeat means the RNG is broken
		t.Errorf("only %d distinct phrases in 50 draws", len(seen))
	}
	if _, err := Generate(wordlist(MinWordlist-1), 5); err == nil {
		t.Error("short word list accepted")
	}
	if _, err := Generate(words, 0); err == nil {
		t.Error("zero words accepted")
	}
}
