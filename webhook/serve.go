package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode"

	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/allowlist"
	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/server"
	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/store"
)

func cmdServe(args []string, e env) error {
	fs := newFlags("serve", e)
	db := dbFlag(fs, e)
	devices := fs.String("devices", e.getenv("DTW_DEVICES"), "allowlist file, lines of HOSTNAME,SERIAL[,note] (env DTW_DEVICES)")
	enrollProv := fs.String("enroll-provisioner", e.getenv("DTW_ENROLL_PROVISIONER"), "name of the SCEP provisioner for enrollment: phrase challenge, single use, pins the host's key (env DTW_ENROLL_PROVISIONER)")
	renewProv := fs.String("renew-provisioner", e.getenv("DTW_RENEW_PROVISIONER"), "name of the SCEP provisioner for renewal: allowed only with the key the host enrolled with, no phrase (env DTW_RENEW_PROVISIONER)")
	listen := fs.String("listen", "127.0.0.1:8081", "address to listen on")
	tlsCert := fs.String("tls-cert", e.getenv("DTW_TLS_CERT"), "TLS certificate (PEM) step-ca will trust; re-read when the file changes (env DTW_TLS_CERT)")
	tlsKey := fs.String("tls-key", e.getenv("DTW_TLS_KEY"), "TLS private key (PEM) (env DTW_TLS_KEY)")
	insecure := fs.Bool("insecure-http", false, "serve plain HTTP. step-ca only calls https webhook URLs, so this is for local testing")
	noSecret := fs.Bool("no-signing-secret", false, "accept step-ca's empty-key signature. A step-ca configured through a static ca.json cannot hold a webhook signing secret and signs with an empty key; keep the server on a private interface")
	secretFile := fs.String("signing-secrets-file", "", "file holding the webhook signing secrets, instead of $DTW_SIGNING_SECRETS")
	if err := parse(fs, args); err != nil {
		return err
	}

	if *devices == "" {
		return usageErr(e, "an allowlist is required: pass -devices or set DTW_DEVICES")
	}
	if *enrollProv == "" && *renewProv == "" {
		return usageErr(e, "name the provisioner(s) to serve: -enroll-provisioner and/or -renew-provisioner")
	}
	useTLS := *tlsCert != "" || *tlsKey != ""
	switch {
	case useTLS && (*tlsCert == "" || *tlsKey == ""):
		return usageErr(e, "-tls-cert and -tls-key must be given together")
	case !useTLS && !*insecure:
		return usageErr(e, "step-ca only calls https webhook URLs: pass -tls-cert and -tls-key (or -insecure-http for local testing)")
	case useTLS && *insecure:
		return usageErr(e, "-insecure-http and -tls-cert/-tls-key are mutually exclusive")
	}
	raw, err := readSecret(e, *secretFile, "DTW_SIGNING_SECRETS")
	if err != nil {
		return err
	}
	// step-ca generates a signing secret per webhook; accept several, separated
	// by whitespace or commas.
	secrets := strings.FieldsFunc(raw, func(r rune) bool { return r == ',' || unicode.IsSpace(r) })
	if len(secrets) == 0 && !*noSecret {
		return usageErr(e, "the webhook signing secret(s) are required: set DTW_SIGNING_SECRETS or -signing-secrets-file (or -no-signing-secret for a static ca.json)")
	}

	list, err := allowlist.Load(*devices)
	if err != nil {
		return err
	}
	st, err := store.Open(*db)
	if err != nil {
		return err
	}
	defer st.Close()

	logger := slog.New(slog.NewTextHandler(e.stderr, nil))
	h, err := server.New(server.Config{
		Allowlist:         list,
		State:             st,
		SigningSecrets:    secrets,
		AllowEmptySecret:  *noSecret,
		EnrollProvisioner: *enrollProv,
		RenewProvisioner:  *renewProv,
		Logger:            logger,
	})
	if err != nil {
		return err
	}

	srv := &http.Server{
		Addr:              *listen,
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
	}
	if useTLS {
		kp, err := newKeyPairReloader(*tlsCert, *tlsKey)
		if err != nil {
			return err
		}
		srv.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12, GetCertificate: kp.GetCertificate}
	}
	logger.Info("listening", "addr", *listen, "tls", useTLS, "path", server.ChallengePath, "devices", list.Len(),
		"enroll-provisioner", *enrollProv, "renew-provisioner", *renewProv, "unsigned-ok", *noSecret)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	errc := make(chan error, 1)
	go func() {
		if useTLS {
			errc <- srv.ListenAndServeTLS("", "")
		} else {
			errc <- srv.ListenAndServe()
		}
	}()
	select {
	case err := <-errc:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return fmt.Errorf("serve: %w", err)
	case <-ctx.Done():
		logger.Info("shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return srv.Shutdown(shutdownCtx)
	}
}

// keyPairReloader serves a TLS certificate from files and picks up a renewed
// certificate without a restart: the files are re-read when either one changes.
type keyPairReloader struct {
	certFile, keyFile string

	mu      sync.Mutex
	cert    *tls.Certificate
	certMod time.Time
	keyMod  time.Time
}

func newKeyPairReloader(certFile, keyFile string) (*keyPairReloader, error) {
	r := &keyPairReloader{certFile: certFile, keyFile: keyFile}
	if _, err := r.GetCertificate(nil); err != nil {
		return nil, err
	}
	return r, nil
}

func (r *keyPairReloader) GetCertificate(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	cs, err := os.Stat(r.certFile)
	if err != nil {
		return nil, err
	}
	ks, err := os.Stat(r.keyFile)
	if err != nil {
		return nil, err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cert != nil && cs.ModTime().Equal(r.certMod) && ks.ModTime().Equal(r.keyMod) {
		return r.cert, nil
	}
	c, err := tls.LoadX509KeyPair(r.certFile, r.keyFile)
	if err != nil {
		if r.cert != nil {
			return r.cert, nil // a half-written renewal: keep serving the last good one
		}
		return nil, err
	}
	r.cert, r.certMod, r.keyMod = &c, cs.ModTime(), ks.ModTime()
	return r.cert, nil
}
