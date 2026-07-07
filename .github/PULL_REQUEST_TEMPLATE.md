## Summary

<!-- One-paragraph description of what this PR changes and why. -->

## Linked Issue

<!-- Use Closes #<n> or Refs #<n>. If there is no issue, explain why. -->

- Closes #
- Refs #

## Component

- [ ] `app` (Flutter)
- [ ] `server` (Fastify + Postgres)
- [ ] `contracts` (Sui Move)
- [ ] `verification_api`
- [ ] `verification_portal`
- [ ] Other (describe)

## Type Of Change

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (fix or feature that would change existing behavior)
- [ ] Documentation only
- [ ] Refactor / cleanup with no behavior change
- [ ] Move / Sui contract change
- [ ] CI / tooling

## On-Chain Impact

<!-- Check all that apply. Leave blank if not applicable. -->

- [ ] Adds or changes a Sui Move entry point
- [ ] Changes an emitted event shape
- [ ] Changes the DNS TXT layout (`_attest.<domain>`)
- [ ] No on-chain impact

<!-- For any on-chain change, paste the exact `sui client` commands, package ID, registry object ID, and any sample transaction digests. State whether the change is additive only or breaking. -->

## Migration Plan

<!-- Required for any breaking change. Describe operator actions, env var changes, package upgrades. -->

## How It Was Tested

<!-- Be specific. Paste commands and outputs. -->

- [ ] `npm run lint`
- [ ] `npm run format:check`
- [ ] `npm run check:server`
- [ ] `npm run check:app`
- [ ] `npm run check:verification_api`
- [ ] `npm run check:verification_portal`
- [ ] `npm run build:server`
- [ ] `npm run test:server`
- [ ] `npm run lint:app` (flutter analyze)
- [ ] `npm run format:app:check`
- [ ] `sui move test` (in `contracts/`)
- [ ] Manual verification (describe below)

```bash
# commands run
```

## Screenshots / Recordings

<!-- Required for any user-visible change. -->

## Documentation

- [ ] Updated the relevant folder `README.md`
- [ ] Updated the root `README.md`
- [ ] No doc change needed

## Security Checklist

- [ ] No secrets, private keys, `.env` values, or production URLs were committed
- [ ] No new dependency with supply-chain risk was added without discussion
- [ ] Authorization, key custody, and biometric/session lifecycle impact was reviewed
- [ ] For on-chain changes: package ID, registry ID, and any sample tx digests are noted above
