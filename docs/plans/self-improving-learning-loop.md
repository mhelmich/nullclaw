# Nullclaw learning loop implementation plan

## Goal

Give Nullclaw a persistent, inspectable learning loop: retain useful low-risk user facts, surface relevant memories in later sessions, draft reusable skills from successful work, and improve skills from recorded outcomes. Memory capture is configurable. Skill changes must be reviewable and reversible.

## Audit findings

Nullclaw already has most of the storage and loading substrate:

- `Agent.auto_save` currently writes each redacted user message and a truncated assistant response as `.conversation` entries (`src/agent/root.zig:2114`, `2642`). That is transcript retention, not fact extraction. It is enabled by default in `MemoryConfig` (`src/config_types.zig:1314`).
- The memory vtable supports keyed store/get/list/forget and session scope (`src/memory/root.zig:310`, `417`). `MemoryRuntime` adds hybrid retrieval, vector sync, and outbox draining (`src/memory/root.zig:578`). `memory_loader` injects a capped set of relevant, filtered memories into the next message (`src/agent/memory_loader.zig:77`).
- Skills are already loaded from workspace directories in `SKILL.toml`, `skill.json`, or `SKILL.md` form; workspace skills override built-ins (`src/skills.zig:530`, `714`, `783`). SkillForge discovers and installs *external* skills; it is not a learning or curation loop (`src/skillforge.zig:7`).
- Tool results and agent history are available at the orchestration layer (`src/agent/root.zig`); the agent already owns the provider, tool surface, memory interface, workspace path, and redactor. This is the right place to collect a compact per-turn learning record.

Hermes provides a useful concrete reference, not a drop-in design. At the audited `main` snapshot (`NousResearch/hermes-agent`, commit `HEAD` recorded during audit), `agent/background_review.py` runs a separate review fork with a narrow tool whitelist and dedicated memory/skill prompts. `tools/skill_usage.py` keeps use/provenance counters outside user skill files, while `tools/skill_manager_tool.py` applies skill writes and guards. It also has mature session search and profile/user-memory separation. Its review machinery is substantial: cancellation, concurrency, token budgets, policy gates, output reporting, and separate memory/provider plumbing. Nullclaw should borrow the separation of concerns and provenance, not port that machinery wholesale.

## Chosen approach

Add a small `learning` subsystem at the agent boundary. Each completed turn produces a bounded, sanitized review input containing the user request, final response, tool names and success/failure summaries, and an explicitly activated skill, if any. A single provider call returns a strict structured result with candidate memory facts, skill drafts/patches, and evidence references. The model does not receive unrestricted tools during review; Nullclaw validates and persists the returned result through narrow code paths.

Learning is opt-in because it adds a second provider request and sends a review payload. `learning.enabled` defaults to `false`; when enabled, review uses the current agent's provider and model, never an implicit auxiliary provider. Memory capture is configurable as `off`, `suggest`, or `auto_low_risk`. `auto_low_risk` stores only explicit preferences, stable user choices, and repeated durable facts. Deterministic secret/PII checks plus a reviewer sensitivity label reject candidates that appear sensitive or uncertain; this is a risk reduction, not a guarantee that semantic filtering catches everything. `suggest` stores candidates in a review queue without injecting them into ordinary context. Existing raw transcript auto-save remains a separate setting and is not consent to the new review call.

Skills use a separate setting: `off`, `draft`, or `auto`. Default `draft` writes generated skills/patches under a pending-learning directory, outside active skill discovery. The user can inspect, promote, reject, or discard drafts. `auto` may activate only validated changes to skills created by the agent; user-authored, bundled, and installed skills remain protected unless explicitly opted in later. Every promotion or automatic update keeps the previous content for rollback.

The first version runs the bounded review synchronously after the final response is formed and before returning the turn result. This reuses the current provider safely, avoids detached threads holding borrowed vtable pointers or agent-owned allocators, and makes failures easy to isolate. It adds one model round trip when learning is enabled; the review is capped, best-effort, and must never turn a successful user response into a failed turn. A later background worker is a separate optimization requiring an owned provider/session lifecycle.

## Data and behavior

1. **Review input:** collect only the current user turn, assistant final answer, compact tool outcome records, and explicitly activated skill ID, if any. Do not infer that a skill was used just because it appeared in the prompt: `buildActiveSkillPromptSection` injects an active skill, but ordinary available skills are also listed as summaries (`src/agent/root.zig:2052`, `src/agent/prompt.zig:861`). Use a learning-specific egress sanitizer even if the optional agent redactor is disabled. If sanitization fails, classification is uncertain, or the payload exceeds its cap, skip the review and persist nothing; never fall back to raw text. Never send whole history, credentials, raw tool output, or memory contents by default. If `learning.enabled=false`, make no review call and collect no learning data, including local outcome-ledger events or curated facts.
2. **Memory facts:** store concise facts in the configured `Memory` backend under a stable key and a distinct custom category, with provenance and confidence included in the content format. User preferences and environment/project facts use distinct key prefixes. Preserve the active agent/profile memory namespace; never write a user-specific fact into shared global memory when multiple users or profiles share a backend. The `Memory` vtable does not promise upsert semantics: enable automatic replacement only for backends whose keyed upsert behavior is verified (SQLite first). On append-only or unsupported backends such as current Markdown, route candidates to `suggest` storage and leave active memory untouched. Do not blindly append every turn. Do not feed pending suggestions into recall. Add a removal path that deletes the active fact and any matching pending candidate/provenance record.
3. **Skill drafts:** create a `SKILL.md` following the existing loader format. Updates are patches against a snapshot/hash of the source skill; reject stale patches if the file changed since review. Validate skill name, size, path containment, frontmatter, and content. Do not allow generated scripts or executable support files in the first release.
4. **Outcome ledger:** only when `learning.enabled=true`, write a local append-only JSONL ledger under workspace state, containing event type, optional explicitly active skill name, optional tool name, timestamp, and opaque turn ID. Events are `skill_activated`, `tool_result` with success/failure, and `user_correction` only when the reviewer can link a clear correction to an explicitly active skill; uncertain attribution is not counted. A task completion without an explicit signal is not success evidence. Do not store prompts, tool arguments, or outputs. Provide cross-process locking and bounded rotation in v1; multiple Nullclaw processes can share a workspace. Do not depend on the selected memory backend for telemetry; remote memory backends must not receive it implicitly. Add `/learning clear` to remove the ledger and pending candidates independently of active memories and skills.
5. **Skill improvement:** use explicit skill activation plus linked user corrections or repeated tool failures as signals; a generic assistant final answer is not proof of success. Tool results are recorded by tool name whether or not a skill can be attributed. Feed recent aggregates and relevant skill text to the reviewer. Draft only changes supported by evidence; preserve the current version and show a diff in review/promotion commands.
6. **User control:** add CLI commands to list/show/promote/reject pending memory and skill candidates, inspect skill outcome summaries, and roll back the latest learned skill change. Existing `memory_forget`/memory commands remain the path to remove active memories.

## Implementation sequence

1. **Define records and policy.** Add typed config enums/defaults and parsing for learning enablement and memory/skill capture modes. Implement learning-record validation, sensitive-content filters, provenance format, and pure unit tests. Document the difference between transcript auto-save and curated capture.
2. **Capture outcomes.** Add a per-turn record to the agent, recording only tool names/status and skill IDs. Ensure it is reset per turn, redacted where text exists, and discarded on cancellation/failure without claiming success. Add deterministic tests for tool success/failure and skill attribution.
3. **Review and capture memories.** Add `src/agent/learning.zig` to build a bounded review request and parse a strict JSON response. Add `learning.enabled` (default false) and memory capture mode (`off`/`suggest`/`auto_low_risk`); make the setting visible in onboard/config docs with the provider-egress consequence. Require verified backend capability for keyed replacement; initially enable auto mode only for SQLite and return candidates to `suggest` on other backends. Tests use a fake provider and in-memory/SQLite backend; no network.
4. **Draft and curate skills.** Add safe draft creation, source-hash checking, diff generation, promotion/rejection/rollback operations, and CLI routing. Drafts remain outside `workspace/skills` until promotion. Use workspace-relative dir handles/no-follow checks and atomic writes; revalidate path, source hash, and skill ownership immediately before promotion to close symlink/TOCTOU gaps. Accept only the existing SKILL.md format and validate the parsed skill name/frontmatter through the same loader before promotion. Add tests for traversal, symlinks, stale source changes, invalid names/frontmatter, rollback, and loaded-skill visibility.
5. **Use outcomes for revision.** Summarize ledger events per skill, trigger review only after meaningful evidence (repeated use plus explicit correction/failure or explicit request), and generate drafts rather than mutate active files. Add tests for thresholding and event aggregation.
6. **Docs and rollout.** Document privacy boundaries, settings, commands, storage/retention, provider-call cost, and rollback. Ship with learning modes configurable and a clear way to disable the extra provider call. Keep the feature dormant if there is no memory backend or no configured provider.

## Hard decisions and tradeoffs

### Synchronous review versus background review

The synchronous bounded call is the recommended first implementation. It costs user-visible latency and a provider request, but has straightforward ownership and cleanup. A worker thread could match Hermes more closely, but Nullclaw's `Provider` is a borrowed vtable and its agent/allocator/session lifecycle is not designed for detached learning jobs. Do not pass `Agent`, `MemoryRuntime`, or provider pointers into a detached thread. If latency proves unacceptable, add an owned job object and explicit join/cancel/drain lifecycle before moving review off-thread.

### Ledger format

Use local JSONL rather than the general memory backend. Memory vtable entries do not have first-class provenance/confidence fields or atomic compare-and-replace; remote backends would also make telemetry egress surprising. JSONL is portable to builds without SQLite. Keep records minimal, use cross-process locking for every append, and rotate by size. Provide `/learning clear` to remove the ledger and pending candidates; retention duration can be a later setting if users need finer control.

### What “auto” means

`learning.enabled` is off until the user opts in; its setting explicitly discloses the extra review request to the configured provider. Once enabled, auto-save applies only to low-risk, high-confidence memory facts. It does not grant the model arbitrary memory writes or permission to mutate arbitrary skills. Skill mode `auto` is limited to agent-created skills with validation and rollback. Keep learned facts and skill changes visibly attributable so users can correct or delete them.

## Validation and rollout

- Add unit tests for JSON validation, privacy filters, deduplication, scope isolation, ledger parsing/rotation, candidate approval, and skill promotion/rollback. Add agent tests proving learning failure does not alter the completed answer and no learning provider call occurs in `off` mode.
- Exercise SQLite active writes and Markdown suggest fallback; verify vector sync after an approved active-memory write. Confirm pending memory is excluded from retrieval and ordinary `memory_list` unless explicitly requested.
- Run `zig fmt --check src/` and `zig build test --summary all`; run the ReleaseSmall build and compare binary/RSS cost because the project treats both as product constraints.
- Keep `learning.enabled` off by default; when enabled, default memory capture to `auto_low_risk` and skill capture to `draft`.

## Open questions

- Should later releases allow learned skills to add auxiliary reference files? The first release stays `SKILL.md`-only to reduce the write surface.

## Key code references

- Nullclaw agent and raw auto-save: `src/agent/root.zig:250-300`, `2114-2128`, `2642-2668`
- Nullclaw memory contract/runtime: `src/memory/root.zig:310-337`, `417-480`, `578-687`
- Memory injection: `src/agent/memory_loader.zig:77-150`, `165-260`
- Skill format and discovery: `src/skills.zig:14-56`, `530-634`, `714-829`
- Skill installation/security path: `src/skills.zig:2177-2225`, `2357-2445`
- Hermes reference: `agent/background_review.py:365-490`, `1092-1132`; `tools/skill_usage.py:1-6`, `500-547`; `tools/skill_manager_tool.py:468-515`, `760-775` at the audited upstream snapshot `d33d4fd9e7b57e16316ca953523bba596e4f6d5e`.
