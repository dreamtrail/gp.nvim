# Roadmap

This roadmap is a high-level guide. The canonical task list is `docs/TODO.md`.

## Current Focus

- Choose the next maintenance priority after completing the native tools milestone.
- Keep the refactored facade architecture maintainable as provider support evolves.

## Near Term

- Broader provider compatibility testing for OpenAI-compatible local servers.
- Watch for user feedback on streamed native tool-use and safety defaults.
- Triage remaining >500 LOC modules if future work touches them.

## Later

- Structured replay of historical markdown tool blocks, only with an approved opt-in provenance-aware design.
- Native tool adapters for Anthropic and Google providers, deferred until there is a concrete provider-specific need.

## Completed Milestones

- Fork maintainer and contributor documentation.
- Core facade refactor for maintainability.
- Native OpenAI-compatible chat tools MVP.
- Default-on streamed native tool-use.
- Local OpenAI-compatible provider smoke validation.
- Native tool safety and UX hardening.
- Size-hygiene split for README, facade, and tests.
- Structured replay evaluation and defer decision.
- Anthropic/Google native tool adapter defer decision.
- Dispatcher status timer crash hotfix.
- Chat newline formatting hotfix.
