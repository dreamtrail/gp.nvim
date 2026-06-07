# Maintainers Guide

This repository is a maintained fork of `gp.nvim`, continued after upstream development slowed/stopped. Keep fork messaging neutral and focused on stewardship, compatibility, and continued maintenance.

## Stewardship goals

- Preserve the plugin's low-dependency Neovim-native design.
- Keep existing user workflows stable unless a breaking change is intentional and documented.
- Prefer configuration compatibility where practical, using `lua/gp/deprecator.lua` for migrations.
- Keep secrets out of logs, docs examples, commits, and generated artifacts.
- Document provider-specific behavior when changing request/response handling.

## Change discipline

For code changes:

1. identify the affected command/provider/module;
2. update the smallest relevant code path;
3. validate with the checks in `docs/TESTING.md`;
4. update README and maintainer docs when user-visible behavior or maintenance process changes;
5. avoid unrelated refactors in provider or buffer-handling code.

For documentation changes:

1. update `README.md` for user-facing behavior;
2. update `docs/` for contributor/maintainer behavior;
3. avoid hand-editing `doc/gp.nvim.txt` unless specifically required;
4. let CI regenerate vimdoc from README.

## Documentation generation

`.github/workflows/docgen.yml` performs two documentation tasks:

1. synchronizes the README config snippet from `lua/gp/config.lua` between `README_REFERENCE_MARKER_START` and `README_REFERENCE_MARKER_END`;
2. runs `panvimdoc` to generate `doc/gp.nvim.txt` from README.

Because of that workflow:

- keep the canonical default config comments in `lua/gp/config.lua` accurate;
- do not treat `doc/gp.nvim.txt` as the source of truth;
- expect README-only changes to create vimdoc drift locally until CI or a maintainer regenerates it.

## Releases

`.github/workflows/release-please.yml` defines a manual `release-please` workflow on `main` using `release-type: simple`.

When preparing releases:

- use Conventional Commits for meaningful changes;
- include user-facing behavior changes in release notes/changelog flow;
- do not include local caches, logs, chat sessions, generated temporary files, or secrets;
- verify generated docs are in the expected state for the release process.

## Provider maintenance

Provider behavior is concentrated in `lua/gp/dispatcher.lua` and `lua/gp/config.lua`.

When adding or changing providers:

- define provider defaults in `config.lua`;
- register secrets through dispatcher/vault rather than leaving raw secrets in public config;
- ensure `prepare_payload()` matches the provider's expected message format;
- check streaming and non-streaming response parsing;
- document model-specific reasoning or attachment behavior;
- validate with the actual provider when possible.

## Security reminders

- Never commit API keys, bearer tokens, password-manager output, `.env` files, or logs containing secrets.
- Prefer secret commands or environment variables in examples.
- Be cautious with `log_sensitive`; it is for local debugging only.
- Treat chat transcripts and prompts as potentially sensitive user data.

## Current testing reality

There is no formal automated test suite in this repository at the time of writing. Maintainers should use the validation guidance in `docs/TESTING.md` and avoid overstating test coverage.

If a test suite is added later, update `docs/TESTING.md`, this guide, and any contributor instructions in README at the same time.
