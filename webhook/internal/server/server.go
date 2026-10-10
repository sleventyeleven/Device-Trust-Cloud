// Package server is the HTTP side of the webhook: it receives step-ca's
// SCEPCHALLENGE webhook calls and decides whether to allow the request. It
// serves two SCEP provisioners, told apart by the (signed) provisionerName in
// the request:
//
// Enrollment: the device sends a challenge computed from its serial number and
// a current enrollment phrase. The webhook looks the CSR's hostname up in the
// allowlist, recomputes the challenge from the serial recorded there, and if it
// matches and the phrase has not already been used by that host, allows the
// request and pins the CSR's public key to the host.
//
// Renewal: no phrase. The webhook allows the request only if the host is still
// on the allowlist and the CSR carries the public key the host enrolled with.
// A certificate issued for that key is useless to anyone without the private
// key, so renewing needs no shared secret at all.
//
// In both cases the host is the CSR's common name (or, if empty, its first DNS
// name), and the CSR may ask for nothing else (see identify).
//
// step-ca signs each call with an HMAC-SHA256 of the body (hex, in
// X-Smallstep-Signature) keyed with the webhook's signing secret, and expects
// {"allow": true|false} in reply. testdata/step_ca_scep_request.json is a
// request produced by step-ca's own types.
package server

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/asn1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/allowlist"
	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/challenge"
	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/store"
)

const (
	// ChallengePath is where step-ca should send SCEPCHALLENGE webhook calls.
	ChallengePath = "/scep/challenge"
	// HealthPath answers 200 without authentication.
	HealthPath = "/healthz"

	maxBody = 1 << 20

	oidSubjectAltName = "2.5.29.17"
)

// Allowlist maps hostnames to devices.
type Allowlist interface {
	Lookup(hostname string) (allowlist.Device, bool, error)
}

// State is the part of the database the handler needs.
type State interface {
	ActivePhrases(ctx context.Context, now time.Time) ([]store.Phrase, error)
	Enroll(ctx context.Context, phraseID int64, host, txn string, pubkey []byte, now time.Time) (bool, error)
	PinFor(ctx context.Context, host string) ([]byte, bool, error)
}

// Config configures a Handler.
type Config struct {
	Allowlist Allowlist
	State     State

	// SigningSecrets are the webhook signing secrets exactly as step-ca shows
	// them (base64). step-ca generates one per webhook, so a server handling two
	// provisioners usually has two. A request is accepted if it is signed with
	// any of them.
	SigningSecrets []string
	// AllowEmptySecret also accepts a signature made with an empty key. A
	// step-ca configured through a static ca.json cannot hold a webhook signing
	// secret (the field is not read from the file) and signs with an empty key.
	// That still detects corruption but proves nothing about the sender, so only
	// use it on a private interface.
	AllowEmptySecret bool

	// EnrollProvisioner and RenewProvisioner are the names of the SCEP
	// provisioners served in each mode. At least one is required; a request
	// from any other provisioner is refused.
	EnrollProvisioner string
	RenewProvisioner  string

	Now    func() time.Time // defaults to time.Now
	Logger *slog.Logger     // defaults to slog.Default()
}

// Handler serves the webhook.
type Handler struct {
	cfg     Config
	secrets [][]byte
	mux     *http.ServeMux
}

// New validates cfg and returns a Handler.
func New(cfg Config) (*Handler, error) {
	if cfg.Allowlist == nil || cfg.State == nil {
		return nil, errors.New("server: allowlist and state store are required")
	}
	if cfg.EnrollProvisioner == "" && cfg.RenewProvisioner == "" {
		return nil, errors.New("server: name at least one provisioner to serve")
	}
	if cfg.EnrollProvisioner == cfg.RenewProvisioner {
		return nil, errors.New("server: the enrollment and renewal provisioners must be different")
	}
	var secrets [][]byte
	for _, s := range cfg.SigningSecrets {
		b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(s))
		if err != nil || len(b) == 0 {
			return nil, errors.New("server: signing secrets must be the base64 strings step-ca shows when a webhook is created")
		}
		secrets = append(secrets, b)
	}
	if cfg.AllowEmptySecret {
		secrets = append(secrets, []byte{})
	}
	if len(secrets) == 0 {
		return nil, errors.New("server: at least one signing secret is required")
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	h := &Handler{cfg: cfg, secrets: secrets, mux: http.NewServeMux()}
	h.mux.HandleFunc("POST "+ChallengePath, h.handleChallenge)
	h.mux.HandleFunc("GET "+HealthPath, func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, "ok\n") })
	return h, nil
}

// ServeHTTP implements http.Handler.
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) { h.mux.ServeHTTP(w, r) }

// The subset of step-ca's request body this server reads.
type requestBody struct {
	ProvisionerName        string `json:"provisionerName"`
	X509CertificateRequest *struct {
		Subject struct {
			CommonName string `json:"commonName"`
		} `json:"subject"`
		Extensions []struct {
			ID    string `json:"id"`
			Value []byte `json:"value"` // DER, base64 in JSON
		} `json:"extensions"`
		PublicKey []byte `json:"publicKey"` // PKIX DER, base64 in JSON
	} `json:"x509CertificateRequest"`
	SCEPChallenge     string `json:"scepChallenge"`
	SCEPTransactionID string `json:"scepTransactionID"`
}

func (h *Handler) validSignature(body []byte, sig []byte) bool {
	ok := false
	for _, secret := range h.secrets { // try all of them, without stopping at the first
		mac := hmac.New(sha256.New, secret)
		mac.Write(body)
		if hmac.Equal(sig, mac.Sum(nil)) {
			ok = true
		}
	}
	return ok
}

func (h *Handler) handleChallenge(w http.ResponseWriter, r *http.Request) {
	log := h.cfg.Logger

	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		http.Error(w, "Bad Request", http.StatusBadRequest)
		return
	}
	sig, err := hex.DecodeString(r.Header.Get("X-Smallstep-Signature"))
	if err != nil || !h.validSignature(body, sig) {
		log.Warn("rejected request with a missing or bad signature", "remote", r.RemoteAddr)
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	var req requestBody
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "Bad Request", http.StatusBadRequest)
		return
	}

	host, allow, reason, err := h.decide(r.Context(), &req)
	if err != nil {
		// A 5xx makes step-ca retry once, which suits a transient failure.
		log.Error("could not evaluate request", "error", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}
	log.Info("scep decision", "allow", allow, "reason", reason, "provisioner", req.ProvisionerName,
		"hostname", host, "transaction", req.SCEPTransactionID)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(struct {
		Allow bool `json:"allow"`
	}{allow})
}

// identify returns the normalised hostname the request claims, after checking
// that the CSR asks for nothing else: every SAN must be a DNS name equal to the
// hostname or one of its subdomains. This matters because the certificate
// template copies the CSR's subject and SANs into the certificate, so a host
// allowed to enroll as "A" could otherwise ask for a certificate naming "B".
func identify(req *requestBody) (string, error) {
	csr := req.X509CertificateRequest
	if csr == nil {
		return "", errors.New("request has no certificate request")
	}

	var dns []string
	sans := 0
	for _, ext := range csr.Extensions {
		if ext.ID != oidSubjectAltName {
			continue
		}
		if sans++; sans > 1 {
			return "", errors.New("certificate request has more than one SAN extension")
		}
		names, err := dnsNames(ext.Value)
		if err != nil {
			return "", err
		}
		dns = names
	}

	name := csr.Subject.CommonName
	if strings.TrimSpace(name) == "" && len(dns) > 0 {
		name = dns[0]
	}
	host, err := challenge.NormalizeSerial(name)
	if err != nil {
		return "", errors.New("certificate request has no usable common name or DNS name")
	}
	for _, n := range dns {
		n = strings.ToUpper(n)
		if n != host && !strings.HasPrefix(n, host+".") {
			return host, fmt.Errorf("certificate request asks for DNS name %q, which is not %s or a subdomain of it", n, host)
		}
	}
	return host, nil
}

// dnsNames decodes a SAN extension value and returns its names, failing if it
// holds anything other than DNS names (email, IP, URI, otherName, ...).
func dnsNames(der []byte) ([]string, error) {
	var seq asn1.RawValue
	if rest, err := asn1.Unmarshal(der, &seq); err != nil || len(rest) != 0 ||
		seq.Class != asn1.ClassUniversal || seq.Tag != asn1.TagSequence {
		return nil, errors.New("certificate request has an unreadable SAN extension")
	}
	var names []string
	for rest := seq.Bytes; len(rest) > 0; {
		var gn asn1.RawValue
		var err error
		if rest, err = asn1.Unmarshal(rest, &gn); err != nil {
			return nil, errors.New("certificate request has an unreadable SAN extension")
		}
		if gn.Class != asn1.ClassContextSpecific || gn.Tag != 2 { // 2 = dNSName
			return nil, errors.New("certificate request has a SAN that is not a DNS name")
		}
		names = append(names, string(gn.Bytes))
	}
	return names, nil
}

// decide returns the hostname it found, whether to allow, and a short reason
// for the log. The error is non-nil only for internal failures, never a denial.
func (h *Handler) decide(ctx context.Context, req *requestBody) (host string, allow bool, reason string, err error) {
	var renew bool
	switch {
	case h.cfg.EnrollProvisioner != "" && req.ProvisionerName == h.cfg.EnrollProvisioner:
	case h.cfg.RenewProvisioner != "" && req.ProvisionerName == h.cfg.RenewProvisioner:
		renew = true
	default:
		return "", false, "request is from a provisioner this server does not serve", nil
	}

	host, ierr := identify(req)
	if ierr != nil {
		return host, false, ierr.Error(), nil
	}
	pub := req.X509CertificateRequest.PublicKey
	if len(pub) == 0 {
		return host, false, "request carries no public key", nil
	}

	dev, listed, err := h.cfg.Allowlist.Lookup(host)
	if err != nil {
		return host, false, "", err
	}
	if !listed {
		return host, false, "hostname is not on the allowlist", nil
	}

	if renew {
		return h.decideRenew(ctx, host, pub)
	}
	return h.decideEnroll(ctx, req, dev, pub)
}

func (h *Handler) decideRenew(ctx context.Context, host string, pub []byte) (string, bool, string, error) {
	pinned, ok, err := h.cfg.State.PinFor(ctx, host)
	if err != nil {
		return host, false, "", err
	}
	if !ok {
		return host, false, "host has no enrolled key: it must enroll first", nil
	}
	if !bytes.Equal(pinned, pub) {
		return host, false, "public key differs from the one the host enrolled with", nil
	}
	return host, true, "renewal with the enrolled key", nil
}

func (h *Handler) decideEnroll(ctx context.Context, req *requestBody, dev allowlist.Device, pub []byte) (string, bool, string, error) {
	host := dev.Hostname
	if req.SCEPChallenge == "" {
		return host, false, "no challenge presented", nil
	}
	now := h.cfg.Now()
	phrases, err := h.cfg.State.ActivePhrases(ctx, now)
	if err != nil {
		return host, false, "", err
	}

	// Compare against every active phrase without stopping at the first match.
	presented := []byte(req.SCEPChallenge)
	var matched []store.Phrase
	for _, p := range phrases {
		want, cerr := challenge.Compute(p.Phrase, dev.Serial)
		if cerr != nil {
			return host, false, "", cerr
		}
		if subtle.ConstantTimeCompare(presented, []byte(want)) == 1 {
			matched = append(matched, p)
		}
	}
	if len(matched) == 0 {
		return host, false, "challenge does not match an active phrase", nil
	}
	for _, p := range matched {
		ok, err := h.cfg.State.Enroll(ctx, p.ID, host, req.SCEPTransactionID, pub, now)
		if err != nil {
			return host, false, "", err
		}
		if ok {
			return host, true, fmt.Sprintf("enrolled with phrase %d; key pinned", p.ID), nil
		}
	}
	return host, false, "phrase already used by this host", nil
}
