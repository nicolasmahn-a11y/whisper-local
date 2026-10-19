#!/bin/sh
# Creates the self-signed code-signing identity "Whisper Local Dev" in the login
# keychain. build.sh signs with it when present, so every build has the same
# designated requirement and macOS privacy grants (Accessibility, Input
# Monitoring, Screen Recording) survive rebuilds. Safe to run again; no admin,
# though macOS may ask for your password once to trust the certificate.
set -eu

name="Whisper Local Dev"
keychain="$HOME/Library/Keychains/login.keychain-db"
if security find-identity -v -p codesigning | grep -q "\"$name\""; then
  printf 'Identity "%s" already exists.\n' "$name"
  exit 0
fi
if security find-identity -p codesigning | grep -q "\"$name\""; then
  printf 'Identity "%s" exists but is not trusted for code signing. Trust it with:\n' "$name"
  printf '  security find-certificate -c "%s" -p > /tmp/wl-cert.pem\n' "$name"
  printf '  security add-trusted-cert -r trustRoot -p codeSign -k "%s" /tmp/wl-cert.pem\n' "$keychain"
  exit 1
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
cat > "$dir/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$dir/cert.conf" \
  -keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null
# Only protects the temporary bundle on its way into the keychain.
pass=$(openssl rand -hex 16)
# OpenSSL 3 needs -legacy for a bundle `security import` can read; LibreSSL has no such flag.
openssl pkcs12 -export -legacy -inkey "$dir/key.pem" -in "$dir/cert.pem" -name "$name" \
  -passout "pass:$pass" -out "$dir/identity.p12" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" -name "$name" \
    -passout "pass:$pass" -out "$dir/identity.p12"
# A self-signed certificate is only a valid signing identity once trusted for code signing.
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$dir/cert.pem"
security import "$dir/identity.p12" -k "$keychain" \
  -P "$pass" -T /usr/bin/codesign
printf 'Created identity "%s". Rebuild with ./build.sh.\n' "$name"
