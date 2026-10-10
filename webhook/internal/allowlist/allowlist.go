// Package allowlist is the set of devices that may enroll, and the serial number
// of each, read from a plain text file (for example a Kubernetes ConfigMap
// mounted into the sidecar, or a file next to the binary). One device per line:
//
//	HOSTNAME,SERIAL[,note]
//
// Blank lines and lines starting with '#' are ignored. Hostnames and serial
// numbers are matched case-insensitively and must each be unique. The file is
// re-read whenever it changes on disk, so editing the ConfigMap takes effect
// without a restart.
package allowlist

import (
	"bufio"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/sleventyeleven/Device-Trust-Cloud/webhook/internal/challenge"
)

// Device is one allowlist entry, with Hostname and Serial in normalised form.
type Device struct {
	Hostname string
	Serial   string
	Note     string
}

// List is a reloading device allowlist.
type List struct {
	path string

	mu      sync.Mutex
	mtime   time.Time
	size    int64
	devices map[string]Device // by normalised hostname
}

// Load reads the file and returns a List, or an error if it cannot be read or
// has an invalid line.
func Load(path string) (*List, error) {
	l := &List{path: path}
	l.mu.Lock()
	defer l.mu.Unlock()
	if err := l.load(); err != nil {
		return nil, err
	}
	return l, nil
}

// Len returns the number of devices currently in the list.
func (l *List) Len() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.devices)
}

// Lookup returns the device with the given hostname. It picks up changes to the
// file first; if the file has become unreadable or invalid it returns an error
// rather than a stale answer.
func (l *List) Lookup(hostname string) (Device, bool, error) {
	norm, err := challenge.NormalizeSerial(hostname)
	if err != nil {
		return Device{}, false, nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if err := l.refresh(); err != nil {
		return Device{}, false, err
	}
	d, ok := l.devices[norm]
	return d, ok, nil
}

func (l *List) refresh() error {
	fi, err := os.Stat(l.path)
	if err != nil {
		return err
	}
	if fi.ModTime().Equal(l.mtime) && fi.Size() == l.size {
		return nil
	}
	return l.load()
}

func (l *List) load() error {
	f, err := os.Open(l.path)
	if err != nil {
		return err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return err
	}

	devices := map[string]Device{}
	serials := map[string]string{} // serial -> hostname that has it
	sc := bufio.NewScanner(f)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(strings.TrimPrefix(sc.Text(), string(rune(0xFEFF))))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		cols := strings.SplitN(line, ",", 3)
		if len(cols) < 2 {
			return fmt.Errorf("%s line %d: expected HOSTNAME,SERIAL[,note]", l.path, n)
		}
		host, err := challenge.NormalizeSerial(cols[0])
		if err != nil {
			return fmt.Errorf("%s line %d: hostname: %w", l.path, n, err)
		}
		serial, err := challenge.NormalizeSerial(cols[1])
		if err != nil {
			return fmt.Errorf("%s line %d: serial: %w", l.path, n, err)
		}
		if _, dup := devices[host]; dup {
			return fmt.Errorf("%s line %d: hostname %s appears more than once", l.path, n, host)
		}
		// Two hosts sharing a serial could answer for each other's challenge.
		if other, dup := serials[serial]; dup {
			return fmt.Errorf("%s line %d: serial %s is already used by %s", l.path, n, serial, other)
		}
		d := Device{Hostname: host, Serial: serial}
		if len(cols) == 3 {
			d.Note = strings.TrimSpace(cols[2])
		}
		devices[host], serials[serial] = d, host
	}
	if err := sc.Err(); err != nil {
		return err
	}
	l.devices, l.mtime, l.size = devices, fi.ModTime(), fi.Size()
	return nil
}
