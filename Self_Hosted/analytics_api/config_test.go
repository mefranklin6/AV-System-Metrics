package main

import (
	"crypto/sha256"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	testToken  = "test-token-0123456789abcdefghijklmnopqrstuv"
	testToken2 = "rotated-token-ZYXWVUTSRQPONMLKJIHGFEDCBA9876543210"
	testDBURL  = "postgres://metrics_reader:reader_password_1234567@postgres:5432/metrics?sslmode=disable"
)

func setValidEnv(t *testing.T) {
	t.Helper()
	t.Setenv("ADDR", "")
	t.Setenv("ANALYTICS_API_TOKEN", testToken)
	t.Setenv("ANALYTICS_DATABASE_URL", testDBURL)
	t.Setenv("ANALYTICS_ALLOWED_NET", "")
	t.Setenv("ANALYTICS_CORS_ORIGINS", "")
	t.Setenv("ANALYTICS_TLS_CERT_FILE", "")
	t.Setenv("ANALYTICS_TLS_KEY_FILE", "")
}

func TestLoadConfigDefaults(t *testing.T) {
	setValidEnv(t)
	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if cfg.addr != ":8081" {
		t.Fatalf("addr = %q, want :8081", cfg.addr)
	}
	if len(cfg.tokenDigests) != 1 || cfg.tokenDigests[0] != sha256.Sum256([]byte(testToken)) {
		t.Fatal("token digest not stored")
	}
	if cfg.allowedNets != nil || len(cfg.corsOrigins) != 0 || cfg.tlsEnabled() {
		t.Fatalf("unexpected optional settings: %+v", cfg)
	}
}

func TestLoadConfigAcceptsMultipleTokensAndOptionalSettings(t *testing.T) {
	setValidEnv(t)
	dir := t.TempDir()
	cert, key := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	for _, p := range []string{cert, key} {
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("ADDR", "127.0.0.1:9000")
	t.Setenv("ANALYTICS_API_TOKEN", " "+testToken+" , "+testToken2+" ")
	t.Setenv("ANALYTICS_ALLOWED_NET", "10.20.0.0/16, 192.0.2.10/32,2001:db8::/32")
	t.Setenv("ANALYTICS_CORS_ORIGINS", "https://Viz.Example.edu, http://localhost:5173/")
	t.Setenv("ANALYTICS_TLS_CERT_FILE", cert)
	t.Setenv("ANALYTICS_TLS_KEY_FILE", key)

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if cfg.addr != "127.0.0.1:9000" || len(cfg.tokenDigests) != 2 || len(cfg.allowedNets) != 3 || !cfg.tlsEnabled() {
		t.Fatalf("unexpected config: %+v", cfg)
	}
	for _, origin := range []string{"https://viz.example.edu", "http://localhost:5173"} {
		if _, ok := cfg.corsOrigins[origin]; !ok {
			t.Fatalf("origin %q not normalized into %v", origin, cfg.corsOrigins)
		}
	}
}

func TestTokenCharset(t *testing.T) {
	for _, ok := range []string{"0123456789abcdefABCDEF", "base64+/token==", "url-safe_token.~"} {
		if !isTokenCharset(ok) {
			t.Fatalf("isTokenCharset(%q) = false", ok)
		}
	}
	for _, bad := range []string{"a b", "a,b", "a$b", "a'b", `a"b`, "a#b", `a\b`, "a`b", "a!b", "a\tb", "é"} {
		if isTokenCharset(bad) {
			t.Fatalf("isTokenCharset(%q) = true", bad)
		}
	}
}

func TestLoadConfigRejectsInvalidSettings(t *testing.T) {
	short := strings.Repeat("a", 31)
	tests := []struct {
		name, key, value, want string
	}{
		{"missing token", "ANALYTICS_API_TOKEN", "", "ANALYTICS_API_TOKEN is required"},
		{"example token", "ANALYTICS_API_TOKEN", exampleAnalyticsToken, "must be changed from the .env.example value"},
		{"example token in list", "ANALYTICS_API_TOKEN", testToken + "," + exampleAnalyticsToken, "must be changed from the .env.example value"},
		{"short token", "ANALYTICS_API_TOKEN", short, "entry 1 must be at least 32 characters"},
		{"short second token", "ANALYTICS_API_TOKEN", testToken + "," + short, "entry 2 must be at least 32 characters"},
		{"empty entry", "ANALYTICS_API_TOKEN", testToken + ",,", "entry 2 is empty"},
		{"token with space", "ANALYTICS_API_TOKEN", strings.Repeat("a", 20) + " " + strings.Repeat("b", 20), "may only contain letters, digits"},
		{"token non-ascii", "ANALYTICS_API_TOKEN", strings.Repeat("a", 32) + "é", "may only contain letters, digits"},
		// Compose interpolates $ in .env, so the API would see a different token.
		{"token with dollar", "ANALYTICS_API_TOKEN", strings.Repeat("a", 32) + "$HOME", "may only contain letters, digits"},
		{"token with quote", "ANALYTICS_API_TOKEN", strings.Repeat("a", 32) + `"`, "may only contain letters, digits"},
		{"token with hash", "ANALYTICS_API_TOKEN", strings.Repeat("a", 32) + "#x", "may only contain letters, digits"},
		{"token with backslash", "ANALYTICS_API_TOKEN", strings.Repeat("a", 32) + `\x`, "may only contain letters, digits"},
		{"missing database url", "ANALYTICS_DATABASE_URL", "", "ANALYTICS_DATABASE_URL is required"},
		{"invalid database url", "ANALYTICS_DATABASE_URL", "postgres://user:pw@host:notaport/db", "must be a valid PostgreSQL connection string"},
		{"example reader password", "ANALYTICS_DATABASE_URL", "postgres://metrics_reader:" + exampleAnalyticsDBPassword + "@postgres/metrics", "change ANALYTICS_DB_PASSWORD"},
		{"example postgres password", "ANALYTICS_DATABASE_URL", "postgres://metrics_user:" + examplePostgresPassword + "@postgres/metrics", "change POSTGRES_PASSWORD"},
		{"bad cidr", "ANALYTICS_ALLOWED_NET", "10.0.0.0/8,not-a-cidr", "entry 2 must be a CIDR"},
		{"bare ip", "ANALYTICS_ALLOWED_NET", "10.0.0.5", "entry 1 must be a CIDR"},
		{"wildcard origin", "ANALYTICS_CORS_ORIGINS", "*", "wildcards and null are not allowed"},
		{"null origin", "ANALYTICS_CORS_ORIGINS", "null", "wildcards and null are not allowed"},
		{"origin with path", "ANALYTICS_CORS_ORIGINS", "https://viz.example.edu/app", "no path"},
		{"origin with query", "ANALYTICS_CORS_ORIGINS", "https://viz.example.edu?x=1", "no path"},
		{"origin with credentials", "ANALYTICS_CORS_ORIGINS", "https://u:p@viz.example.edu", "no path"},
		{"origin bad scheme", "ANALYTICS_CORS_ORIGINS", "ftp://viz.example.edu", "must use http or https"},
		{"origin without scheme", "ANALYTICS_CORS_ORIGINS", "viz.example.edu", "must look like"},
		{"empty origin entry", "ANALYTICS_CORS_ORIGINS", "https://a.example.edu,", "entry 2 is empty"},
		{"tls cert without key", "ANALYTICS_TLS_CERT_FILE", "cert.pem", "must be set together"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			setValidEnv(t)
			t.Setenv(tt.key, tt.value)
			_, err := loadConfig()
			if err == nil {
				t.Fatalf("loadConfig accepted %s", tt.name)
			}
			if !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("error = %q, want it to contain %q", err.Error(), tt.want)
			}
		})
	}
}

func TestLoadConfigErrorsNeverContainSecrets(t *testing.T) {
	secret := "SuperSecretValueThatMustNotLeak"
	cases := map[string]string{
		"ANALYTICS_API_TOKEN":    secret,
		"ANALYTICS_DATABASE_URL": "postgres://metrics_reader:" + secret + "@host:badport/metrics",
	}
	for key, value := range cases {
		setValidEnv(t)
		t.Setenv(key, value)
		_, err := loadConfig()
		if err == nil {
			t.Fatalf("%s: expected an error", key)
		}
		if strings.Contains(err.Error(), secret) {
			t.Fatalf("%s: error leaks the secret: %q", key, err.Error())
		}
	}
}

func TestLoadConfigRejectsMissingTLSFiles(t *testing.T) {
	setValidEnv(t)
	dir := t.TempDir()
	t.Setenv("ANALYTICS_TLS_CERT_FILE", filepath.Join(dir, "missing-cert.pem"))
	t.Setenv("ANALYTICS_TLS_KEY_FILE", filepath.Join(dir, "missing-key.pem"))
	if _, err := loadConfig(); err == nil || !strings.Contains(err.Error(), "must point to a readable file") {
		t.Fatalf("err = %v, want readable file error", err)
	}
}

func TestLoadConfigRejectsTooManyTokens(t *testing.T) {
	setValidEnv(t)
	tokens := make([]string, maxTokens+1)
	for i := range tokens {
		tokens[i] = testToken
	}
	t.Setenv("ANALYTICS_API_TOKEN", strings.Join(tokens, ","))
	if _, err := loadConfig(); err == nil || !strings.Contains(err.Error(), "at most") {
		t.Fatalf("err = %v, want too many tokens", err)
	}
}
