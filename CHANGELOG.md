# Changelog

## Unreleased

### ai-analyzer reliability (feature/error-log)
- Fixed event-loop blocking in `/analyze` and `/identify` by running analysis on a worker thread (`asyncio.to_thread`).
- Added per-request correlation IDs (`[req=XXXXXXXX]` log prefix, `X-Request-Id` response header) for end-to-end tracing.
- Surfaced Gemini safety blocks and non-`STOP` finish reasons in logs instead of returning silent empty results.
- Added `error_code`/`warnings` fields to ai-analyzer responses and surfaced them in the mobile UI.
- Gave the pubsub-worker's ai-analyzer call its own configurable timeout (`AI_ANALYZER_TIMEOUT_SECONDS`, default 120s).
