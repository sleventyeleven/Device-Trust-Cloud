package challenge

import (
	"fmt"
	"strings"
	"testing"
)

const testPhrase = "Queen-Ate-Lamp-Wise-Smell"

// The expected values below were NOT produced by this package. They were
// computed independently with OpenSSL 3.5.5:
//
//	printf 'device-trust-scep-challenge-v1\n%s' "$SERIAL" |
//	  openssl dgst -sha256 -hmac "$PHRASE" -binary | openssl base64 -A
//
// and with Windows PowerShell 5.1 (.NET HMACSHA256), which agreed exactly.
// They pin the formula so a server and its client scripts can never silently
// drift apart.
var knownAnswers = []struct {
	name, id, want string
}{
	{"mac style", "C02ABC123XYZ", "6ZR262r4trPJ6vKSEOgBATU4m8NXj97z0oOmBt/wo8c="},
	{"serial with spaces", "TO BE FILLED BY O.E.M.", "n9JP3tnNTzNs6upeL3+Y6mLcqJGCvUmUd3O1RzRLRBw="},
	{"windows bios style", "5CG1234ABC", "Iy1ZxsVc0+LSidy2uk8+B0v5o+8CmaU83JjWnWDEAtk="},
}

func TestComputeKnownAnswers(t *testing.T) {
	for _, tc := range knownAnswers {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Compute(testPhrase, tc.id)
			if err != nil {
				t.Fatalf("Compute: %v", err)
			}
			if got != tc.want {
				t.Errorf("Compute(%q) = %q, want %q", tc.id, got, tc.want)
			}
		})
	}
}

func TestComputeNormalizesID(t *testing.T) {
	want, _ := Compute(testPhrase, "C02ABC123XYZ")
	for _, raw := range []string{"c02abc123xyz", "  C02ABC123XYZ", "C02ABC123XYZ\r\n", "\tc02Abc123xYz \n"} {
		got, err := Compute(testPhrase, raw)
		if err != nil || got != want {
			t.Errorf("Compute(%q) = %q, %v; want %q", raw, got, err, want)
		}
	}
}

func TestComputeSeparatesInputs(t *testing.T) {
	base, _ := Compute(testPhrase, "C02ABC123XYZ")
	for name, other := range map[string]func() (string, error){
		"serial":      func() (string, error) { return Compute(testPhrase, "C02ABC123XYY") },
		"phrase":      func() (string, error) { return Compute("Queen-Ate-Lamp-Wise-Smelt", "C02ABC123XYZ") },
		"phrase case": func() (string, error) { return Compute(strings.ToLower(testPhrase), "C02ABC123XYZ") },
	} {
		if got, _ := other(); got == base {
			t.Errorf("changing the %s did not change the challenge", name)
		}
	}
}

func TestComputeErrors(t *testing.T) {
	if _, err := Compute("", "C02ABC123XYZ"); err == nil {
		t.Error("empty phrase: want error")
	}
	if _, err := Compute(testPhrase, "  "); err == nil {
		t.Error("blank id: want error")
	}
}

func TestNormalizeSerial(t *testing.T) {
	ok := map[string]string{
		"abc123":                 "ABC123",
		"  abc123 \r\n":          "ABC123",
		"to be filled by o.e.m.": "TO BE FILLED BY O.E.M.",
		"laptop-01.example.com":  "LAPTOP-01.EXAMPLE.COM",
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
	for _, p := range []string{"Queen-Ate-Lamp-Wise-Smell", "x", "a-b"} {
		if err := ValidatePhrase(p); err != nil {
			t.Errorf("ValidatePhrase(%q) = %v", p, err)
		}
	}
	for name, p := range map[string]string{
		"empty": "", "space": "Queen Ate", "non ascii": "Smëll", "control": "a\x07b", "too long": strings.Repeat("a", MaxPhraseLen+1),
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
