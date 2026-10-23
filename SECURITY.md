# Security and public-source hygiene

DomoHome loads device configuration locally and resolves secrets through macOS Keychain. Tuya credentials and device identifiers are supplied to the message helper through stdin, never command-line arguments. The helper does not implement an unlock operation.

Release defaults to the public `PROD` channel name; Debug defaults to `TEST`. An explicit environment selection is stored in the user's local preferences. Channel names, Tuya public endpoints, DP numbers and configuration field names are not credentials. Each installation supplies its own project credentials and device identifiers.

Do not commit real credentials, device identifiers, network addresses, private signing material, local configuration, broker payloads, diagnostics containing user data, or screenshots that expose them. Use empty placeholders in `.env.example` and synthetic values in tests. Keep signing overrides in the ignored `Config/Signing.local.xcconfig`. Required third-party license notices and public author attribution must remain intact.

Before publishing changes, install Gitleaks and run:

```sh
bash scripts/audit-secrets.sh
```

The audit checks the working directory and Git history, with detected values fully redacted. Git ignore rules are a convenience, not a security boundary. Review new images and binary artifacts separately because textual scanning cannot establish that they contain no sensitive data.

If a real secret has been committed, revoke or rotate it first. Removing it from the current files does not remove it from Git history or existing remote copies. Coordinate any history rewrite with repository maintainers before changing shared history. Report vulnerabilities privately through the maintainer contact on the repository profile; do not post credentials or exploit details in public issues.
