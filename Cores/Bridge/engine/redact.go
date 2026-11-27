package engine

import (
	"bytes"
	"encoding/json"
	"regexp"
	"sort"
	"strings"
	"sync/atomic"
)

// Redaction of configuration values (ADR-0003 §4: configuration, keys and server addresses are never written
// to a log). Error messages of the core quote what they reject — an id, a key, an address — and the host
// logs error messages publicly, so every message the bridge returns or logs passes through a redactor built
// from the configuration it is about. The rules match the Swift compiler's ConfigValueRedactor
// (Packages/ConfigurationEngine/Sources/ConfigValueRedactor.swift).

const redactedPlaceholder = "[redacted]"

// structuralKeys hold values that describe the document's shape (protocol and transport names, tags).
var structuralKeys = map[string]bool{
	"protocol": true, "network": true, "security": true, "tag": true, "outboundTag": true, "balancerTag": true,
	"inboundTag": true, "loglevel": true, "flow": true, "fingerprint": true, "type": true, "mode": true,
	"strategy": true, "domainStrategy": true, "queryStrategy": true, "method": true, "alpn": true,
	"congestion": true, "packetEncoding": true, "selector": true, "fallbackTag": true, "subjectSelector": true,
	"cipher": true, "headerType": true, "header": true, "auth_mode": true,
}

// sensitiveKeys hold credentials and addresses: their values are removed even when short.
var sensitiveKeys = map[string]bool{
	"id": true, "password": true, "pass": true, "user": true, "username": true, "auth": true, "address": true,
	"endpoint": true, "serverName": true, "serverNames": true, "publicKey": true, "privateKey": true,
	"secretKey": true, "preSharedKey": true, "shortId": true, "shortIds": true, "spiderX": true,
	"mldsa65Verify": true, "mldsa65Seed": true, "seed": true, "key": true, "host": true, "path": true,
	"servers": true, "encryption": true, "decryption": true, "certificate": true,
	"pinnedPeerCertificateSha256": true, "echConfigList": true, "serviceName": true, "dest": true, "target": true,
	"remotePorts": true,
}

var commonWords = map[string]bool{
	"none": true, "auto": true, "true": true, "false": true, "tcp": true, "udp": true, "tcp,udp": true, "raw": true,
	"tls": true, "http": true, "https": true, "reality": true, "chrome": true, "firefox": true, "safari": true,
	"random": true, "noauth": true, "freedom": true, "blackhole": true,
}

const (
	minSensitiveLen = 4
	minOtherLen     = 6
)

// redactPatterns remove UUIDs and IP literals whatever their source (the core may print an address in a
// normalised form that is not in the document).
var redactPatterns = []*regexp.Regexp{
	regexp.MustCompile(`[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}`),
	regexp.MustCompile(`\b(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\b`),
	regexp.MustCompile(`(?:[0-9A-Fa-f]{1,4}:){1,7}:(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6})?`),
	regexp.MustCompile(`(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}`),
	regexp.MustCompile(`::[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6}`),
}

// redactor removes the values of one configuration from text.
type redactor struct {
	values []string // longest first
}

// newRedactor collects the values of a configuration. A document that is not valid JSON (the parse error
// is being reported) contributes every string literal of 4 characters and more instead.
func newRedactor(config []byte) *redactor {
	seen := map[string]bool{}
	var doc any
	dec := json.NewDecoder(bytes.NewReader(config))
	dec.UseNumber()
	if err := dec.Decode(&doc); err == nil {
		collectValues(doc, "", seen)
	} else {
		for _, m := range stringLiteral.FindAllSubmatch(config, -1) {
			if s := strings.TrimSpace(string(m[1])); len(s) >= minSensitiveLen && !commonWords[strings.ToLower(s)] {
				seen[s] = true
			}
		}
	}
	r := &redactor{}
	for v := range seen {
		r.values = append(r.values, v)
	}
	sort.Slice(r.values, func(i, j int) bool {
		if len(r.values[i]) != len(r.values[j]) {
			return len(r.values[i]) > len(r.values[j])
		}
		return r.values[i] < r.values[j]
	})
	return r
}

var stringLiteral = regexp.MustCompile(`"((?:[^"\\]|\\.)*)"`)

func collectValues(v any, key string, seen map[string]bool) {
	switch t := v.(type) {
	case string:
		if key == "" || structuralKeys[key] {
			return
		}
		s := strings.TrimSpace(t)
		if commonWords[strings.ToLower(s)] {
			return
		}
		min := minOtherLen
		if sensitiveKeys[key] {
			min = minSensitiveLen
		}
		if len(s) >= min {
			seen[s] = true
		}
	case []any:
		for _, item := range t {
			collectValues(item, key, seen)
		}
	case map[string]any:
		for k, item := range t {
			collectValues(item, k, seen)
		}
	}
}

// redact returns text without the configuration's values, UUIDs and IP literals. For error messages.
func (r *redactor) redact(text string) string {
	text = r.redactValues(text)
	for _, p := range redactPatterns {
		text = p.ReplaceAllString(text, redactedPlaceholder)
	}
	return text
}

// redactLog returns a core log line without the configuration's values and UUIDs. Other IP literals stay:
// they are destinations of the user's traffic, which the host logs as private data (ADR-0003 §4).
func (r *redactor) redactLog(text string) string {
	return redactPatterns[0].ReplaceAllString(r.redactValues(text), redactedPlaceholder)
}

func (r *redactor) redactValues(text string) string {
	if r != nil {
		for _, v := range r.values {
			text = replaceFold(text, v)
		}
	}
	return text
}

// replaceFold replaces every case-insensitive occurrence of value (the core lower-cases some fields).
func replaceFold(text, value string) string {
	if value == "" {
		return text
	}
	lowerText, lowerValue := strings.ToLower(text), strings.ToLower(value)
	if len(lowerText) != len(text) || len(lowerValue) != len(value) {
		// Lower-casing changed byte lengths (non-ASCII): fall back to an exact match.
		return strings.ReplaceAll(text, value, redactedPlaceholder)
	}
	if !strings.Contains(lowerText, lowerValue) {
		return text
	}
	var b strings.Builder
	for {
		i := strings.Index(lowerText, lowerValue)
		if i < 0 {
			b.WriteString(text)
			return b.String()
		}
		b.WriteString(text[:i])
		b.WriteString(redactedPlaceholder)
		text, lowerText = text[i+len(value):], lowerText[i+len(value):]
	}
}

// redactError rewrites err's message in place and returns it.
func (r *redactor) redactError(err *Error) *Error {
	if err != nil {
		err.Message = r.redact(err.Message)
	}
	return err
}

// activeRedactor is applied to every record of the core's log. It is replaced on each start and kept after a
// stop, so that the lines of the shutdown are redacted too.
var activeRedactor atomic.Pointer[redactor]
