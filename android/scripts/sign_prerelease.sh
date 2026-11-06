#!/usr/bin/env bash
# Signs the Release APK for a prerelease. Usage: sign_prerelease.sh <unsigned.apk> <out.apk>
#
# With ANDROID_KEYSTORE_BASE64 / ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_ALIAS set (repository
# secrets) it signs with that release key. Otherwise it uses a throwaway key, which is fine for a
# prerelease to try out but cannot update an install signed by another key.
set -euo pipefail
in="$1"; out="$2"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?ANDROID_HOME is not set}}"
tools="$(ls -d "$sdk"/build-tools/* | sort -V | tail -1)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

if [[ -n "${ANDROID_KEYSTORE_BASE64:-}" ]]; then
  printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 --decode > "$work/release.jks"
  keystore="$work/release.jks"; alias="${ANDROID_KEY_ALIAS:?}"; pass="${ANDROID_KEYSTORE_PASSWORD:?}"
  echo "Signing with the repository release key"
else
  keystore="$work/prerelease.jks"; alias=pulso-prerelease; pass="$(openssl rand -hex 16)"
  keytool -genkeypair -keystore "$keystore" -alias "$alias" -storepass "$pass" -keypass "$pass" \
    -keyalg RSA -keysize 3072 -validity 3650 -dname "CN=Pulso prerelease" >/dev/null 2>&1
  echo "Signing with a throwaway prerelease key"
fi

"$tools/zipalign" -f -p 4 "$in" "$work/aligned.apk"
"$tools/apksigner" sign --ks "$keystore" --ks-key-alias "$alias" --ks-pass "pass:$pass" --out "$out" "$work/aligned.apk"
"$tools/apksigner" verify "$out"
