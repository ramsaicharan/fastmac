# Releasing a signed, notarized FastMac

Notarized builds open with macOS's standard prompt — *"FastMac is an app downloaded from the
Internet. Are you sure you want to open it?"* — instead of being blocked. They also keep
privacy permissions such as Full Disk Access across updates.

Notarization needs a paid Apple Developer account. Steps 1–4 are done once by the maintainer;
after that, every tagged release is signed and notarized automatically.

## 1. Join the Apple Developer Program

Enroll at [developer.apple.com/programs](https://developer.apple.com/programs/) as an
individual (US$99 a year). Approval can take up to two days.

## 2. Create a Developer ID certificate

1. In Xcode, open **Settings → Accounts**, select your Apple Account and click
   **Manage Certificates…**.
2. Click **+** and choose **Developer ID Application**.
3. In **Keychain Access → My Certificates**, right-click
   **Developer ID Application: Your Name (TEAMID)** → **Export…**, save it as a `.p12` file
   and choose a password.

Keep the `.p12` file and its password private. Delete the exported file once step 4 is done.

## 3. Create a notary API key

1. In [App Store Connect](https://appstoreconnect.apple.com), open
   **Users and Access → Integrations → App Store Connect API → Team Keys**.
2. Generate a key with the **Developer** role and download `AuthKey_XXXXXXXXXX.p8`. Apple
   lets you download it only once.
3. Note the **Key ID** and the **Issuer ID** shown on that page.

## 4. Add the repository secrets

In GitHub, open **Settings → Secrets and variables → Actions** and add:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_P12` | The `.p12` file, base64-encoded: `base64 -i DeveloperID.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The password you chose when exporting |
| `APPLE_API_KEY_P8` | The contents of the `.p8` file: `pbcopy < AuthKey_XXXXXXXXXX.p8` |
| `APPLE_API_KEY_ID` | The Key ID |
| `APPLE_API_ISSUER_ID` | The Issuer ID |

## 5. Release

```bash
git tag v2.0.1 && git push origin v2.0.1
```

The release workflow imports the certificate into a temporary keychain, builds with the
hardened runtime, submits the app to Apple, staples the notarization ticket, confirms that
Gatekeeper accepts it and publishes the zip. The release notes say the build is notarized.

## Notarizing locally

```bash
xcrun notarytool store-credentials fastmac \
  --key AuthKey_XXXXXXXXXX.p8 --key-id <Key ID> --issuer <Issuer ID>
FASTMAC_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' scripts/bundle.sh
FASTMAC_NOTARY_PROFILE=fastmac scripts/notarize.sh
```

`scripts/notarize.sh` refuses ad-hoc builds and prints Apple's log if a submission is rejected.
