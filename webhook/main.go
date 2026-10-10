// Command device-trust-webhook is a step-ca webhook server that gives each
// device its own SCEP challenge. A SCEP request is allowed only if the device is
// on the allowlist and its challenge is the HMAC of its serial number (or
// hostname) under one of the currently valid shared phrases.
//
// Run "device-trust-webhook help" for the commands, or see README.md.
package main

import (
	"fmt"
	"io"
	"os"
)

const usage = `device-trust-webhook - per-device SCEP challenges for step-ca

Usage: device-trust-webhook <command> [flags]

  serve                 run the webhook server
  phrase new            generate an enrollment phrase from a word list, store it, print it
  phrase add            store a phrase you made yourself
  phrase list           list phrases, their expiry and how many hosts used them
  phrase revoke <id>    stop accepting a phrase immediately
  uses list             show which host enrolled with which phrase
  uses reset <hostname> let a host enroll again with a phrase it has already used
  pins list             show the key each host enrolled with (what renewals must match)
  pins clear <hostname> forget a host's key; it must enroll again before it can renew
  challenge <serial>    print the challenge for a device serial number

Every command accepts -h. The database is -db or $DTW_DB
(default device-trust-webhook.db). Secrets (the step-ca signing secret, phrases)
are read from the environment or a file, never from flags.
`

// env bundles what commands need from the process so tests can fake it.
type env struct {
	stdout, stderr io.Writer
	stdin          io.Reader
	getenv         func(string) string
}

func main() {
	os.Exit(run(os.Args[1:], env{os.Stdout, os.Stderr, os.Stdin, os.Getenv}))
}

func run(args []string, e env) int {
	if len(args) == 0 {
		fmt.Fprint(e.stderr, usage)
		return 2
	}
	cmd, rest := args[0], args[1:]
	var err error
	switch cmd {
	case "help", "-h", "-help", "--help":
		fmt.Fprint(e.stdout, usage)
		return 0
	case "serve":
		err = cmdServe(rest, e)
	case "phrase":
		err = cmdPhrase(rest, e)
	case "uses":
		err = cmdUses(rest, e)
	case "pins":
		err = cmdPins(rest, e)
	case "challenge":
		err = cmdChallenge(rest, e)
	default:
		fmt.Fprintf(e.stderr, "unknown command %q\n\n%s", cmd, usage)
		return 2
	}
	switch err {
	case nil, errHelp:
		return 0
	case errUsage:
		return 2
	}
	fmt.Fprintf(e.stderr, "error: %v\n", err)
	return 1
}
