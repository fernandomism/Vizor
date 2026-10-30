#!/bin/sh
# Loads the "Vizor Signing" certificate from GitHub secrets into a temporary keychain so build.sh signs
# with it. A stable signature lets macOS keep Vizor's Accessibility permission across updates.
# Without the secret (forks, or before it's set up) this does nothing and the build stays ad-hoc signed.
set -e
[ -n "$SIGNING_CERT_P12" ] || exit 0
keychain="$RUNNER_TEMP/signing.keychain-db"
security create-keychain -p "" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "" "$keychain"
printf '%s' "$SIGNING_CERT_P12" | base64 --decode > "$RUNNER_TEMP/signing.p12"
security import "$RUNNER_TEMP/signing.p12" -k "$keychain" -P "$SIGNING_CERT_PASSWORD" -f pkcs12 -T /usr/bin/codesign
rm "$RUNNER_TEMP/signing.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$keychain" > /dev/null
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
security find-identity -p codesigning "$keychain"
echo "SIGN_IDENTITY=Vizor Signing" >> "$GITHUB_ENV"
