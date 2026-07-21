# Contributing

1. Keep authentication and token ownership in `puc-config-manager`.
2. Keep each feature's business inputs in that feature's `module_config.example.json`.
3. Use generic adapter and file names; never encode a server address in a filename.
4. Preserve the no-command-line-parameters contract for the public CMD entry point.
5. Add focused module tests for every behavior change.
6. Run module tests and `Test-RepositorySafety.ps1` before committing.
7. Never commit real IP addresses, credentials, ciphertext, HAR data, reports, or tokens.

Use pull requests for changes. Describe API contract changes and include sanitized request/response shapes when adding a module.
