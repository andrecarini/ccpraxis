#!/bin/bash
# Scan files for sensitive data patterns. Exits non-zero if any found.
# Used by /backup before committing to prevent accidental secret leaks.
set -e

DIR="${1:-.}"
FOUND=0

# Patterns that suggest sensitive data
PATTERNS=(
  'sk-ant-'           # Anthropic API keys
  'sk-[a-zA-Z0-9]{20}'  # Generic secret keys
  'AIza[a-zA-Z0-9_-]'   # Google API keys
  'Bearer [a-zA-Z0-9_-]'  # Bearer tokens
  'accessToken'       # OAuth tokens
  'PRIVATE KEY'       # Private keys
  'password\s*[:=]'   # Hardcoded passwords
  'secret\s*[:=]'     # Hardcoded secrets
  'dsn.*sentry'       # Sentry DSNs (with actual values)
  'https://[^"]*@[^"]*\.ingest\.' # Sentry ingest URLs
  'credentials_json'  # GCP credentials
  'deploy_key'        # Deploy keys
)

for pattern in "${PATTERNS[@]}"; do
  MATCHES=$(grep -rnE "$pattern" "$DIR" \
    --include='*.pl' --include='*.sh' --include='*.md' --include='*.json' \
    2>/dev/null | grep -v '.gitignore' | grep -v 'sensitive-check.sh' | grep -v 'README.md' \
    | grep -v '{accessToken}' | grep -v '>{accessToken}' \
    | grep -v 'credentials_json.*secrets\.' || true)
  if [ -n "$MATCHES" ]; then
    if [ "$FOUND" -eq 0 ]; then
      echo "SENSITIVE DATA DETECTED — do NOT push until resolved:"
      echo ""
    fi
    FOUND=1
    echo "  Pattern: $pattern"
    echo "$MATCHES" | sed 's/^/    /'
    echo ""
  fi
done

if [ "$FOUND" -eq 0 ]; then
  echo "No sensitive data found."
fi

exit $FOUND
