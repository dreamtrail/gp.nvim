# Roadmap

This roadmap is a high-level guide. The canonical task list is `docs/TODO.md`.

## Current Focus

- Validate native chat tools against the local OpenAI-compatible provider.
- Harden tool safety and UX based on audit follow-ups.
- Keep the refactored facade architecture maintainable as tool support expands.

## Near Term

- Manual smoke testing for tool-enabled local chat agents.
- Follow-up hardening for confirmation behavior, command allowlists, path revalidation, and large-file edit UX.
- Split oversized files identified by size hygiene.

## Later

- Structured replay of historical markdown tool blocks.
- Native tool adapters for Anthropic and Google providers.
- Broader provider compatibility testing for OpenAI-compatible local servers.

## Completed Milestones

- Fork maintainer and contributor documentation.
- Core facade refactor for maintainability.
- Native OpenAI-compatible chat tools MVP.
- Dispatcher status timer crash hotfix.
- Chat newline formatting hotfix.
