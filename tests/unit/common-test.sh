#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-common-test.XXXXXX")"

# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"
# shellcheck source=../../lib/local-ai-common.sh
source "$ROOT/lib/local-ai-common.sh"

cleanup() {
  [[ "$TEST_TMP" == */local-ai-common-test.* ]] || return 1
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

config_file="$TEST_TMP/setup.env"
cat > "$config_file" <<'EOF'
PORT_EXTRA=9999
PORT=8080
ROUTING_PROFILE=sticky
PORT=9090
EMPTY=
EOF

assert_eq 9090 "$(local_ai_config_get "$config_file" PORT 1234)" \
  "config lookup uses the last exact key"
assert_eq sticky "$(local_ai_config_get "$config_file" ROUTING_PROFILE quality)" \
  "config lookup returns a persisted value"
assert_eq fallback "$(local_ai_config_get "$config_file" MISSING fallback)" \
  "config lookup returns its fallback"
assert_eq fallback "$(local_ai_config_get "$config_file" EMPTY fallback)" \
  "empty persisted value does not erase a fallback"
ln -s "$config_file" "$TEST_TMP/setup-link.env"
assert_eq safe "$(local_ai_config_get "$TEST_TMP/setup-link.env" PORT safe)" \
  "config lookup refuses symlink input"

assert_eq 18.0.100 "$(local_ai_semver_from_text 'oh-my-pi version 18.0.100 (release)')" \
  "semantic version extraction keeps complete components"
expect_success "help token matcher accepts an exact option" \
  local_ai_help_has_option '--reasoning --reasoning-effort VALUE' --reasoning
expect_failure "help token matcher rejects a suffixed lookalike" \
  local_ai_help_has_option '--reasoning-effort VALUE' --reasoning
expect_success "help token matcher accepts comma-delimited options" \
  local_ai_help_has_option 'options: --model, --flash-attn=MODE' --flash-attn

valid_key=abcdefghijklmnopqrstuvwxyzABCDEF0123456789._~-
expect_success "API key validator accepts the documented safe alphabet" \
  local_ai_api_key_valid "$valid_key"
expect_failure "API key validator rejects a short key" \
  local_ai_api_key_valid short
expect_failure "API key validator rejects shell/HTTP metacharacters" \
  local_ai_api_key_valid 'abcdefghijklmnopqrstuvwxyz12345!'

key_file="$TEST_TMP/llama.key"
printf '%s' "$valid_key" > "$key_file"
assert_eq "$valid_key" "$(local_ai_api_key_from_file "$key_file")" \
  "API key reader accepts a newline-free regular file"
ln -s "$key_file" "$TEST_TMP/llama-link.key"
expect_failure "API key reader refuses symlinks" \
  local_ai_api_key_from_file "$TEST_TMP/llama-link.key"

artifact="$TEST_TMP/artifact.gguf"
printf 'fixture' > "$artifact"
assert_eq 7 "$(local_ai_file_size "$artifact")" "portable file-size helper reports bytes"
identity_before="$(local_ai_file_identity "$artifact")"
printf 'fixture-expanded' > "$artifact"
identity_after="$(local_ai_file_identity "$artifact")"
[[ "$identity_before" != "$identity_after" ]] || test_fail "file identity did not change after replacement"
test_pass "verification identity changes with artifact metadata"

printf 'AAAA' > "$artifact"
identity_before="$(local_ai_file_identity "$artifact")"
printf 'BBBB' > "$artifact"
identity_after="$(local_ai_file_identity "$artifact")"
[[ "$identity_before" != "$identity_after" ]] || \
  test_fail "file identity missed an immediate same-size overwrite"
test_pass "verification identity includes sub-second change timestamps"

mock_bin="$TEST_TMP/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${CURL_ARGV_LOG:?}"
cat > "${CURL_STDIN_LOG:?}"
printf '{"ok":true}\n'
EOF
chmod 755 "$mock_bin/curl"
curl_argv_log="$TEST_TMP/curl.argv"
curl_stdin_log="$TEST_TMP/curl.stdin"
response="$(PATH="$mock_bin:$PATH" CURL_ARGV_LOG="$curl_argv_log" \
  CURL_STDIN_LOG="$curl_stdin_log" \
  local_ai_curl_authenticated "$key_file" --silent http://127.0.0.1:8080/v1/models)"
assert_eq '{"ok":true}' "$response" "authenticated curl returns command output"
assert_file_contains "$curl_stdin_log" "Authorization: Bearer ${valid_key}" \
  "authenticated curl supplies the key over stdin"
assert_file_not_contains "$curl_argv_log" "$valid_key" \
  "authenticated curl keeps the key out of argv"

printf 'Shared-helper unit tests passed.\n'
