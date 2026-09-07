# Permissions and signing

Mac Themes requests Accessibility permission to operate Brave and ChatGPT's
native theme controls. macOS may also request Automation permission for Ghostty
or System Events. **Setup & status** reports the permission recognized by the
running app; **Refresh detection** rechecks it without applying a theme.

If Accessibility is enabled but remains unrecognized, quit and reopen the
installed app first. When migrating from an old ad-hoc signed build, remove its
stale entry in System Settings → Privacy & Security → Accessibility, then add
the installed Mac Themes app again. Repeated toggling should not be necessary
for normal theme changes. The permission panel's name can vary by macOS release.

## Local development identity

`scripts/sign.sh` creates and reuses a local code-signing identity in a dedicated
keychain under `~/Library/Application Support/Mac Themes Signing`. Keep this
private directory across builds. It is never included in the source or ZIP.
Incomplete signing state stops the build instead of silently replacing the
identity. The keychain is locked after signing; global certificate trust and
privacy permissions are not modified.

The designated requirement binds both the certificate and bundle identifier.
Changing a build therefore preserves identity, while the separately identified
Preview app cannot satisfy the main app's requirement. `scripts/test-signing.sh`
checks this using disposable copies without launching them.

This local signature is not a Developer ID signature or Apple notarization.
Public distribution needs a separate Developer ID signing and notarization step.
