# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This is a JFrog reference repository demonstrating how to create, attach, and manage **evidence** (signed metadata) in Artifactory using the JFrog CLI. It showcases a complete DevOps workflow where Docker images are built, tested, scanned, and promoted through environments (DEV → QA → PROD) with cryptographic evidence attached at each stage and OPA policy verification before promotion.

## Application

The Go app (`main.go`) is a simple HTTP server on port 9001 that uses Levenshtein string similarity. It exists as a vehicle for demonstrating the evidence workflow — not as the primary focus.

```bash
# Build
go build -o go-server .

# Run tests
go test

# Run with coverage (for SonarQube)
go test -coverprofile=coverage.out
```

## Architecture

### Evidence Lifecycle

1. **Build stage**: Docker image built (multi-arch amd64/arm64), pushed to Artifactory Docker registry
2. **Evidence attachment**: Multiple evidence predicates attached to the image:
   - `signature/v1` — cryptographic signature (actor, timestamp)
   - `testing-results/v1` — test pass/fail results
   - `sonar-scan/v1` — SonarQube code quality results
   - `approval/v1` — human or automated approval gate
3. **Release Bundle v2**: Immutable snapshot created from build info, signed with GPG key
4. **Promotion with policy check**: Before promoting DEV→QA or QA→PROD, OPA evaluates the evidence graph via GraphQL API

### Key CI/CD Workflows

- **`1-build-with-evidence.yml`** — Build, push, attach evidence, create release bundle
- **`2-evidence-and-policy-check.yml`** — Full pipeline: build → QA promotion → OPA policy check → PROD promotion
- **`sonar-evidence-example.yml`** — SonarQube-specific evidence workflow
- **`snippets/`** — Minimal standalone examples (Jira, ZAP, ServiceNow, simple flow)

### Policy Engine

`policy/policy.rego` validates that all required evidence slugs (`cyclonedx-vex`, `testing-results`, `promotion`) exist on an artifact before allowing PROD promotion. The evidence graph is fetched via GraphQL (`scripts/graphql_query.gql`) from the Artifactory Evidence API.

### Integration Examples

`examples/` contains standalone Go tools for generating evidence from:
- SonarQube scan results (`sonar-scan-example/`)
- Jira ticket transitions (`jira-transition-example/`)
- ServiceNow change requests (`service-now evidence/`)

## JFrog CLI Evidence Commands

```bash
# Attach evidence to a package (Docker image)
jf evd create \
  --package-name <NAME> --package-version <VERSION> \
  --package-repo-name <REPO> \
  --key <PRIVATE_KEY_FILE> --key-alias <ALIAS> \
  --predicate <PREDICATE_JSON> --predicate-type <TYPE_URI>

# Attach evidence to a build
jf evd create \
  --build-name <NAME> --build-number <NUMBER> \
  --key <KEY> --key-alias <ALIAS> \
  --predicate <FILE> --predicate-type <TYPE>

# Attach evidence to a release bundle
jf evd create \
  --release-bundle <NAME> --release-bundle-version <VERSION> \
  --key <KEY> --key-alias <ALIAS> \
  --predicate <FILE> --predicate-type <TYPE>
```

## Required Secrets & Variables

| Name | Purpose |
|------|---------|
| `JF_URL` / `ARTIFACTORY_URL` | JFrog Platform URL |
| `PRIVATE_KEY_EXPORT` | Private key for signing evidence |
| `PRIVATE_KEY_NAME` | Private key filename |
| `GPG_KEY_NAME` | GPG key for release bundle signing |
| `SONAR_TOKEN` | SonarCloud authentication |
| `BUILD_NAME` | Build identifier in Artifactory |
| `BUNDLE_NAME` | Release Bundle identifier |
| `JF_PROJECT` | JFrog Project key |
