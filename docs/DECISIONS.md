# Decisions

## 2026-07-06 — Chat finder storage and migration

- Use `:GpChatMigrate [dry-run|apply]` as the explicit migration command.
- Treat no-argument `:GpChatMigrate` as `dry-run`.
- Require confirmation for `:GpChatMigrate apply` before moving legacy flat chats.
- Make `YYYY/MM/*.md` the canonical layout discovered by `:GpChatFinder`.
- Ignore root-level flat chats in finder discovery/search until users explicitly migrate them.
- Keep direct-path opening and existing `last_chat` behavior for flat chats when the file still exists.
- Keep migration simple: do not inspect loaded buffers; document that users should close legacy chat buffers before applying migration.
- Keep migration idempotent and conflict-safe: do not overwrite existing targets; users can rerun migration.
