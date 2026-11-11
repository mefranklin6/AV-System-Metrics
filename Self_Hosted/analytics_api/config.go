package main

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"net/netip"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

const (
	defaultAddr = ":8081"

	// Example values shipped in .env.example. The service refuses to run with them.
	exampleAnalyticsToken      = "change-me-long-random-analytics-token"
	exampleAnalyticsDBPassword = "change_me_url_safe_analytics_password"
	examplePostgresPassword    = "change_me_url_safe_database_password"

	minTokenLength   = 32
	maxTokenLength   = 512
	maxTokens        = 64
	maxAllowedNets   = 256
	maxCORSOrigins   = 32
	defaultProvision = 15 * time.Minute
)

// config is the validated runtime configuration of the API server.
// It deliberately keeps only SHA-256 digests of the API tokens.
type config struct {
	addr         string
	tokenDigests [][sha256.Size]byte
	databaseURL  string
	allowedNets  []netip.Prefix
	corsOrigins  map[string]struct{}
	tlsCertFile  string
	tlsKeyFile   string
}

func (c config) tlsEnabled() bool { return c.tlsCertFile != "" && c.tlsKeyFile != "" }

// loadConfig reads and validates the API server configuration from the environment.
func loadConfig() (config, error) {
	cfg := config{addr: getenvDefault("ADDR", defaultAddr)}

	tokens, err := parseTokens(os.Getenv("ANALYTICS_API_TOKEN"))
	if err != nil {
		return cfg, err
	}
	cfg.tokenDigests = make([][sha256.Size]byte, 0, len(tokens))
	for _, token := range tokens {
		cfg.tokenDigests = append(cfg.tokenDigests, sha256.Sum256([]byte(token)))
	}

	cfg.databaseURL = strings.TrimSpace(os.Getenv("ANALYTICS_DATABASE_URL"))
	if cfg.databaseURL == "" {
		return cfg, errors.New("ANALYTICS_DATABASE_URL is required")
	}
	if err := validateDatabaseURL("ANALYTICS_DATABASE_URL", cfg.databaseURL); err != nil {
		return cfg, err
	}

	if cfg.allowedNets, err = parseAllowedNets(os.Getenv("ANALYTICS_ALLOWED_NET")); err != nil {
		return cfg, err
	}
	if cfg.corsOrigins, err = parseCORSOrigins(os.Getenv("ANALYTICS_CORS_ORIGINS")); err != nil {
		return cfg, err
	}

	cfg.tlsCertFile = strings.TrimSpace(os.Getenv("ANALYTICS_TLS_CERT_FILE"))
	cfg.tlsKeyFile = strings.TrimSpace(os.Getenv("ANALYTICS_TLS_KEY_FILE"))
	if (cfg.tlsCertFile == "") != (cfg.tlsKeyFile == "") {
		return cfg, errors.New("ANALYTICS_TLS_CERT_FILE and ANALYTICS_TLS_KEY_FILE must be set together")
	}
	for name, path := range map[string]string{"ANALYTICS_TLS_CERT_FILE": cfg.tlsCertFile, "ANALYTICS_TLS_KEY_FILE": cfg.tlsKeyFile} {
		if path == "" {
			continue
		}
		info, err := os.Stat(path)
		if err != nil || info.IsDir() {
			return cfg, fmt.Errorf("%s must point to a readable file", name)
		}
	}

	return cfg, nil
}

// parseTokens validates the comma-separated ANALYTICS_API_TOKEN list.
// Error messages never include token values.
func parseTokens(raw string) ([]string, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, errors.New("ANALYTICS_API_TOKEN is required")
	}
	parts := strings.Split(raw, ",")
	if len(parts) > maxTokens {
		return nil, fmt.Errorf("ANALYTICS_API_TOKEN may list at most %d tokens", maxTokens)
	}
	tokens := make([]string, 0, len(parts))
	for i, part := range parts {
		token := strings.TrimSpace(part)
		position := i + 1
		switch {
		case token == "":
			return nil, fmt.Errorf("ANALYTICS_API_TOKEN entry %d is empty (remove extra commas)", position)
		case token == exampleAnalyticsToken:
			return nil, errors.New("ANALYTICS_API_TOKEN must be changed from the .env.example value")
		case len(token) < minTokenLength:
			return nil, fmt.Errorf("ANALYTICS_API_TOKEN entry %d must be at least %d characters", position, minTokenLength)
		case len(token) > maxTokenLength:
			return nil, fmt.Errorf("ANALYTICS_API_TOKEN entry %d must be at most %d characters", position, maxTokenLength)
		case !isTokenCharset(token):
			return nil, fmt.Errorf("ANALYTICS_API_TOKEN entry %d may only contain letters, digits, and . _ ~ + / = - (for example from openssl rand -hex 32)", position)
		}
		tokens = append(tokens, token)
	}
	return tokens, nil
}

// isTokenCharset accepts letters, digits, and the URL-safe and base64
// punctuation . _ ~ + / = -. Characters such as $, quotes, backslash, and #
// are rejected because Docker Compose interpolates or strips them in .env, so
// the API would silently receive a different token than the one handed out.
// update.sh applies the same rule.
func isTokenCharset(token string) bool {
	for i := 0; i < len(token); i++ {
		c := token[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9':
		case c == '.', c == '_', c == '~', c == '+', c == '/', c == '=', c == '-':
		default:
			return false
		}
	}
	return true
}

// validateDatabaseURL checks that the value parses as a PostgreSQL connection
// string and does not carry an example password. The underlying parse error
// is intentionally not wrapped because it could quote the connection string.
func validateDatabaseURL(name, databaseURL string) error {
	pgConfig, err := pgconn.ParseConfig(databaseURL)
	if err != nil {
		return fmt.Errorf("%s must be a valid PostgreSQL connection string", name)
	}
	switch pgConfig.Password {
	case exampleAnalyticsDBPassword:
		return fmt.Errorf("%s uses the .env.example ANALYTICS_DB_PASSWORD; change ANALYTICS_DB_PASSWORD", name)
	case examplePostgresPassword:
		return fmt.Errorf("%s uses the .env.example POSTGRES_PASSWORD; change POSTGRES_PASSWORD", name)
	}
	return nil
}

func parseAllowedNets(raw string) ([]netip.Prefix, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	parts := strings.Split(raw, ",")
	if len(parts) > maxAllowedNets {
		return nil, fmt.Errorf("ANALYTICS_ALLOWED_NET may list at most %d networks", maxAllowedNets)
	}
	nets := make([]netip.Prefix, 0, len(parts))
	for i, part := range parts {
		value := strings.TrimSpace(part)
		prefix, err := netip.ParsePrefix(value)
		if err != nil {
			return nil, fmt.Errorf("ANALYTICS_ALLOWED_NET entry %d must be a CIDR such as 10.20.0.0/16 or 192.0.2.10/32", i+1)
		}
		nets = append(nets, prefix.Masked())
	}
	return nets, nil
}

func parseCORSOrigins(raw string) (map[string]struct{}, error) {
	origins := map[string]struct{}{}
	if strings.TrimSpace(raw) == "" {
		return origins, nil
	}
	parts := strings.Split(raw, ",")
	if len(parts) > maxCORSOrigins {
		return nil, fmt.Errorf("ANALYTICS_CORS_ORIGINS may list at most %d origins", maxCORSOrigins)
	}
	for i, part := range parts {
		origin, err := normalizeOrigin(strings.TrimSpace(part))
		if err != nil {
			return nil, fmt.Errorf("ANALYTICS_CORS_ORIGINS entry %d %s", i+1, err.Error())
		}
		origins[origin] = struct{}{}
	}
	return origins, nil
}

// normalizeOrigin accepts only exact http(s) origins (scheme://host[:port]).
func normalizeOrigin(value string) (string, error) {
	if value == "" {
		return "", errors.New("is empty (remove extra commas)")
	}
	if strings.Contains(value, "*") || strings.EqualFold(value, "null") {
		return "", errors.New("must be an exact origin; wildcards and null are not allowed")
	}
	u, err := url.Parse(value)
	if err != nil || u.Host == "" || u.Opaque != "" {
		return "", errors.New("must look like https://viz.example.edu")
	}
	scheme := strings.ToLower(u.Scheme)
	if scheme != "https" && scheme != "http" {
		return "", errors.New("must use http or https")
	}
	if u.User != nil || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" || u.ForceQuery {
		return "", errors.New("must be only scheme://host[:port] with no path, query, or credentials")
	}
	return scheme + "://" + strings.ToLower(u.Host), nil
}

func getenvDefault(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}
