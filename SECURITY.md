# Security Policy

## Reporting a Vulnerability

Please do not open public GitHub issues for security vulnerabilities.

Use one of the following private channels:

1. GitHub Security Advisories for this repository ("Report a vulnerability").
2. Datadog security contact: `security@datadoghq.com`.

Include:
- affected version/commit
- reproduction steps or proof-of-concept
- impact assessment

## Disclosure Expectations

- We will acknowledge receipt as quickly as possible.
- We will investigate, validate impact, and coordinate remediation.
- When a fix is available, we will coordinate disclosure timing with reporters.

## Scope

This policy covers the code and documentation in this repository, including:
- Bazel module extension/repository rules under `tools/core`
- Go companion module under `modules/go`
- Python companion module under `modules/python`
- Java companion module under `modules/java`
- NodeJS companion module under `modules/nodejs`
- .NET companion module under `modules/dotnet`
- Ruby companion module under `modules/ruby`
- Integration harnesses under `tools/tests`
