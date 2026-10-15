package main

import (
	"context"
	"crypto/sha256"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/challenge"
	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/store"
)

var (
	// errUsage means the problem was already reported to the user.
	errUsage = errors.New("usage")
	// errHelp means -h was given.
	errHelp = errors.New("help")
)

func newFlags(name string, e env) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(e.stderr)
	return fs
}

func parse(fs *flag.FlagSet, args []string) error {
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return errHelp
		}
		return errUsage
	}
	return nil
}

func dbFlag(fs *flag.FlagSet, e env) *string {
	def := "device-trust-webhook.db"
	if v := e.getenv("DTW_DB"); v != "" {
		def = v
	}
	return fs.String("db", def, "path to the SQLite database (env DTW_DB)")
}

func usageErr(e env, format string, a ...any) error {
	fmt.Fprintf(e.stderr, format+"\n", a...)
	return errUsage
}

// readSecret returns a secret from a file ('-' is stdin) or, if no file is
// named, from the environment variable, with surrounding whitespace trimmed.
func readSecret(e env, file, envVar string) (string, error) {
	switch file {
	case "":
		return strings.TrimSpace(e.getenv(envVar)), nil
	case "-":
		b, err := io.ReadAll(io.LimitReader(e.stdin, 1<<16))
		return strings.TrimSpace(string(b)), err
	}
	b, err := os.ReadFile(file)
	return strings.TrimSpace(string(b)), err
}

func cmdPhrase(args []string, e env) error {
	if len(args) == 0 {
		return usageErr(e, "usage: device-trust-webhook phrase <new|add|list|revoke> ...")
	}
	switch sub, rest := args[0], args[1:]; sub {
	case "new":
		return phraseNew(rest, e)
	case "add":
		return phraseAdd(rest, e)
	case "list":
		return phraseList(rest, e)
	case "revoke":
		return phraseRevoke(rest, e)
	default:
		return usageErr(e, "unknown phrase command %q", sub)
	}
}

const defaultExpiry = 30 * 24 * time.Hour // phrases are rotated monthly

func storePhrase(e env, db, phrase string, expiresIn time.Duration) error {
	if expiresIn <= 0 {
		return usageErr(e, "-expires-in must be positive")
	}
	st, err := store.Open(db)
	if err != nil {
		return err
	}
	defer st.Close()
	now := time.Now()
	id, err := st.AddPhrase(context.Background(), phrase, now, now.Add(expiresIn))
	if err != nil {
		return err
	}
	fmt.Fprintf(e.stderr, "stored phrase %d, valid until %s\n", id, now.Add(expiresIn).UTC().Format(time.RFC3339))
	return nil
}

func phraseNew(args []string, e env) error {
	fs := newFlags("phrase new", e)
	db := dbFlag(fs, e)
	list := fs.String("wordlist", e.getenv("DTW_WORDLIST"), "word list file, one word per line; EFF/diceware files work as they are (env DTW_WORDLIST)")
	words := fs.Int("words", 5, "number of words in the phrase")
	expires := fs.Duration("expires-in", defaultExpiry, "how long the phrase stays valid, e.g. 720h")
	if err := parse(fs, args); err != nil {
		return err
	}
	if *list == "" {
		return usageErr(e, "a word list is required: pass -wordlist or set DTW_WORDLIST")
	}
	f, err := os.Open(*list)
	if err != nil {
		return err
	}
	defer f.Close()
	ws, err := challenge.ParseWordlist(f)
	if err != nil {
		return err
	}
	phrase, err := challenge.Generate(ws, *words)
	if err != nil {
		return err
	}
	if err := storePhrase(e, *db, phrase, *expires); err != nil {
		return err
	}
	// The phrase alone goes to stdout so an automation can capture it.
	fmt.Fprintln(e.stdout, phrase)
	return nil
}

func phraseAdd(args []string, e env) error {
	fs := newFlags("phrase add", e)
	db := dbFlag(fs, e)
	file := fs.String("phrase-file", "", "read the phrase from this file ('-' for stdin) instead of $DTW_PHRASE")
	expires := fs.Duration("expires-in", defaultExpiry, "how long the phrase stays valid, e.g. 720h")
	if err := parse(fs, args); err != nil {
		return err
	}
	phrase, err := readSecret(e, *file, "DTW_PHRASE")
	if err != nil {
		return err
	}
	if phrase == "" {
		return usageErr(e, "no phrase given: set DTW_PHRASE or use -phrase-file")
	}
	return storePhrase(e, *db, phrase, *expires)
}

func phraseList(args []string, e env) error {
	fs := newFlags("phrase list", e)
	db := dbFlag(fs, e)
	if err := parse(fs, args); err != nil {
		return err
	}
	st, err := store.Open(*db)
	if err != nil {
		return err
	}
	defer st.Close()
	ps, err := st.ListPhrases(context.Background())
	if err != nil {
		return err
	}
	now := time.Now()
	tw := tabwriter.NewWriter(e.stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "ID\tSTATUS\tCREATED\tEXPIRES\tHOSTS USED")
	for _, p := range ps { // the phrase itself is never printed
		fmt.Fprintf(tw, "%d\t%s\t%s\t%s\t%d\n", p.ID, p.Status(now),
			p.CreatedAt.Format(time.RFC3339), p.ExpiresAt.Format(time.RFC3339), p.Uses)
	}
	return tw.Flush()
}

func phraseRevoke(args []string, e env) error {
	fs := newFlags("phrase revoke", e)
	db := dbFlag(fs, e)
	if err := parse(fs, args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageErr(e, "usage: device-trust-webhook phrase revoke [-db path] <id>")
	}
	id, err := strconv.ParseInt(fs.Arg(0), 10, 64)
	if err != nil {
		return usageErr(e, "phrase id must be a number (see 'phrase list')")
	}
	st, err := store.Open(*db)
	if err != nil {
		return err
	}
	defer st.Close()
	if err := st.RevokePhrase(context.Background(), id, time.Now()); err != nil {
		return err
	}
	fmt.Fprintf(e.stdout, "revoked phrase %d\n", id)
	return nil
}

func cmdUses(args []string, e env) error {
	if len(args) == 0 {
		return usageErr(e, "usage: device-trust-webhook uses <list|reset> ...")
	}
	sub, rest := args[0], args[1:]
	if sub != "list" && sub != "reset" {
		return usageErr(e, "unknown uses command %q", sub)
	}
	fs := newFlags("uses "+sub, e)
	db := dbFlag(fs, e)
	if err := parse(fs, rest); err != nil {
		return err
	}
	st, err := store.Open(*db)
	if err != nil {
		return err
	}
	defer st.Close()
	ctx := context.Background()

	if sub == "reset" {
		if fs.NArg() != 1 {
			return usageErr(e, "usage: device-trust-webhook uses reset [-db path] <hostname>")
		}
		id, err := challenge.NormalizeSerial(fs.Arg(0))
		if err != nil {
			return err
		}
		n, err := st.ResetUses(ctx, id)
		if err != nil {
			return err
		}
		fmt.Fprintf(e.stdout, "cleared %d use(s) for %s\n", n, id)
		return nil
	}

	us, err := st.ListUses(ctx)
	if err != nil {
		return err
	}
	tw := tabwriter.NewWriter(e.stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "PHRASE\tHOST\tWHEN\tSCEP TRANSACTION")
	for _, u := range us {
		fmt.Fprintf(tw, "%d\t%s\t%s\t%s\n", u.PhraseID, u.Device, u.UsedAt.Format(time.RFC3339), u.Txn)
	}
	return tw.Flush()
}

func cmdChallenge(args []string, e env) error {
	fs := newFlags("challenge", e)
	file := fs.String("phrase-file", "", "read the phrase from this file ('-' for stdin) instead of $DTW_PHRASE")
	if err := parse(fs, args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageErr(e, "usage: device-trust-webhook challenge [-phrase-file file] <serial>")
	}
	phrase, err := readSecret(e, *file, "DTW_PHRASE")
	if err != nil {
		return err
	}
	if err := challenge.ValidatePhrase(phrase); err != nil {
		return fmt.Errorf("phrase (from DTW_PHRASE or -phrase-file): %w", err)
	}
	c, err := challenge.Compute(phrase, fs.Arg(0))
	if err != nil {
		return err
	}
	fmt.Fprintln(e.stdout, c)
	return nil
}

func cmdPins(args []string, e env) error {
	if len(args) == 0 {
		return usageErr(e, "usage: device-trust-webhook pins <list|clear> ...")
	}
	sub, rest := args[0], args[1:]
	if sub != "list" && sub != "clear" {
		return usageErr(e, "unknown pins command %q", sub)
	}
	fs := newFlags("pins "+sub, e)
	db := dbFlag(fs, e)
	if err := parse(fs, rest); err != nil {
		return err
	}
	st, err := store.Open(*db)
	if err != nil {
		return err
	}
	defer st.Close()
	ctx := context.Background()

	if sub == "clear" {
		if fs.NArg() != 1 {
			return usageErr(e, "usage: device-trust-webhook pins clear [-db path] <hostname>")
		}
		host, err := challenge.NormalizeSerial(fs.Arg(0))
		if err != nil {
			return err
		}
		ok, err := st.ClearPin(ctx, host)
		if err != nil {
			return err
		}
		if !ok {
			return fmt.Errorf("host %s has no pinned key", host)
		}
		fmt.Fprintf(e.stdout, "cleared the pinned key for %s; it must enroll again before it can renew\n", host)
		return nil
	}

	pins, err := st.ListPins(ctx)
	if err != nil {
		return err
	}
	tw := tabwriter.NewWriter(e.stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "HOST\tKEY SHA-256\tENROLLED\tPHRASE")
	for _, p := range pins {
		sum := sha256.Sum256(p.Key)
		fmt.Fprintf(tw, "%s\t%x\t%s\t%d\n", p.Host, sum[:8], p.SetAt.Format(time.RFC3339), p.PhraseID)
	}
	return tw.Flush()
}
