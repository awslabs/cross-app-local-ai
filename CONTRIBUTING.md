# Contributing to FastLang

Thank you for your interest in contributing to FastLang! We welcome bug reports,
feature requests, and pull requests.

## How to Contribute

### Reporting Bugs

- Open an issue describing the bug, steps to reproduce, and expected vs. actual behavior.
- Include your macOS version and any relevant logs from Console.app (filter by `com.fastlang`).

### Suggesting Features

- Open an issue with a clear description of the feature and the problem it solves.

### Pull Requests

1. Fork the repository and create a branch from `main`.
2. Follow the project setup instructions in `README.md` (`make generate`, etc.).
3. Make your changes, ensuring:
   - Code compiles without warnings.
   - All tests pass: `make test`
   - Swift files include the license header (see `Tools/add_license_headers.sh`).
4. Write clear commit messages following [Conventional Commits](https://www.conventionalcommits.org/).
5. Open a pull request against `main` with a description of the change.

### Code Style

- SwiftLint and swift-format are used for linting and formatting.
- Run `swiftlint --strict` and `swift-format lint --recursive Sources Tests FastLang Views`
  before submitting.

## Security

If you discover a potential security issue, please do **not** open a public issue.
Instead, email joehcott@amazon.com directly.

## Licensing

By submitting a pull request, you agree that your contributions will be licensed
under the [MIT License](LICENSE) that covers this project.
