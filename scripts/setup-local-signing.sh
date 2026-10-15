#!/bin/zsh
# Run once, with the user's consent: creates a persistent local signing key.
set -euo pipefail
umask 077

project_dir="${0:A:h:h}"
identity_name="Wordglide Local Development"
identity_file="$project_dir/.local/signing-identity"
keychain_path="${WORDGLIDE_SIGNING_KEYCHAIN:-}"
if [[ -z "$keychain_path" ]]; then
  keychain_path="$(/usr/bin/security default-keychain -d user | /usr/bin/sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/')"
fi
if [[ ! -f "$keychain_path" ]]; then
  print -u2 -- "Login keychain not found. Set WORDGLIDE_SIGNING_KEYCHAIN to an existing user keychain."
  exit 1
fi
keychain_path="${keychain_path:A}"
if [[ ! -O "$keychain_path" || "$keychain_path" == /Library/Keychains/* || "$keychain_path" == /System/* ]]; then
  print -u2 -- "Only a keychain owned by the current user is supported. No system keychain will be changed."
  exit 1
fi

signing_temp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/wordglide-signing.XXXXXX")"
trap '/bin/rm -rf -- "$signing_temp_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

valid_identities() {
  /usr/bin/security find-identity -v -p codesigning "$keychain_path"
}
identity_is_valid() {
  valid_identities | /usr/bin/awk -v fingerprint="$1" 'toupper($2) == toupper(fingerprint) { found=1 } END { exit !found }'
}
certificate_fingerprint() {
  /usr/bin/openssl x509 -in "$1" -noout -fingerprint -sha1 | /usr/bin/awk -F= '{gsub(":", "", $2); print toupper($2)}'
}
save_identity() {
  /bin/mkdir -p "$project_dir/.local"
  local pending_file
  pending_file="$(/usr/bin/mktemp "$project_dir/.local/signing-identity.XXXXXX")"
  print -r -- "$1" > "$pending_file"
  /bin/mv -f -- "$pending_file" "$identity_file"
  print -- "Configured local signing identity: $1"
  print -- "Private key stays in the user keychain; no key is saved in the project."
  print -- "Next: scripts/build-app.sh"
}

# Never silently replace a previously configured identity: that would invalidate
# the application's privacy identity and bring back the original problem.
if [[ -f "$identity_file" ]]; then
  configured_identity="$(<"$identity_file")"
  if [[ "$configured_identity" =~ '^[[:xdigit:]]{40}$' ]] && identity_is_valid "$configured_identity"; then
    print -- "Local signing is already configured: $configured_identity"
    exit 0
  fi
  print -u2 -- "The configured signing identity is unavailable. Restore its certificate/private key or check keychain trust; it will not be replaced."
  exit 1
fi

certificate_file="$signing_temp_dir/certificate.pem"
if ! /usr/bin/security find-certificate -a -c "$identity_name" -p "$keychain_path" > "$certificate_file" 2>/dev/null; then
  print -u2 -- "Cannot read the user keychain. Unlock it before configuring signing."
  exit 1
fi
certificate_count="$(/usr/bin/awk '/BEGIN CERTIFICATE/ { n++ } END { print n+0 }' "$certificate_file")"
if [[ "$certificate_count" -gt 1 ]]; then
  print -u2 -- "Multiple local signing certificates exist. Choose the intended SHA-1 with WORDGLIDE_SIGNING_IDENTITY; no certificate was changed."
  exit 1
fi
if [[ "$certificate_count" == 1 ]]; then
  fingerprint="$(certificate_fingerprint "$certificate_file")"
  if identity_is_valid "$fingerprint"; then
    save_identity "$fingerprint"
    exit 0
  fi
  # A previous interrupted setup may have imported the pair before the trust
  # confirmation completed. Only finish that same identity, never mint another.
  if ! /usr/bin/security find-identity -p codesigning "$keychain_path" | /usr/bin/awk -v fingerprint="$fingerprint" 'toupper($2) == fingerprint { found=1 } END { exit !found }'; then
    print -u2 -- "A same-named certificate exists without a usable private key. Resolve it in Keychain Access; this script will not overwrite it."
    exit 1
  fi
else
  cat > "$signing_temp_dir/openssl.cnf" <<'EOF'
[req]
distinguished_name = subject
x509_extensions = code_signing
prompt = no
[subject]
CN = Wordglide Local Development
[code_signing]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
  print -- "Creating a Wordglide-only local code-signing identity in the user keychain."
  /usr/bin/openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
    -config "$signing_temp_dir/openssl.cnf" -keyout "$signing_temp_dir/private-key.pem" \
    -out "$certificate_file" > /dev/null 2>&1
  # The temporary private PEM is mode 600 inside a mode 700 directory. It is
  # deleted on exit. The imported key is non-extractable and only codesign is
  # pre-authorized to use it; never grant the -A (all applications) ACL.
  /usr/bin/security import "$certificate_file" -k "$keychain_path" -t cert
  /usr/bin/security import "$signing_temp_dir/private-key.pem" -k "$keychain_path" \
    -t priv -x -T /usr/bin/codesign
  fingerprint="$(certificate_fingerprint "$certificate_file")"
fi

# User-domain trust for code signing only. No admin/system keychain, SSL trust,
# TCC edits, or privacy grants are performed here. macOS may ask the user to
# confirm this trust setting in its own authorization dialog.
/usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$keychain_path" "$certificate_file"
if ! identity_is_valid "$fingerprint"; then
  print -u2 -- "The identity is not yet valid for code signing. Finish the macOS keychain confirmation, then run this script again."
  exit 1
fi
save_identity "$fingerprint"
