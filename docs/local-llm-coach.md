# Local / self-hosted LLM support for the AI Coach

Branch: `feat/local-llm-coach`. Adds a `localOpenAICompat` coach provider that points at any
OpenAI-**Chat-Completions**-compatible server the user runs themselves — Ollama, llama.cpp
(`llama-server`), vLLM, SGLang, LM Studio, and anything else speaking the same wire format —
with the API key **optional**.

Ported from the Android implementation (PulseLoopAndroid #51), including the review fixes that
landed on top of it. §§1, 2, 5, 5a and 5b are protocol facts and carry over unchanged; §3
(cleartext) and §4 (timeouts) are genuinely different on iOS and are rewritten here. Where the
two platforms diverge, this file is authoritative for iOS.

## 1. What the engines actually implement

Every popular local engine converged on the same de-facto standard: OpenAI's **Chat Completions**
(`POST {base}/v1/chat/completions`) plus `GET {base}/v1/models`. None of them implement the
OpenAI **Responses** API in the form this app speaks natively (Ollama and llama.cpp expose a
`/v1/responses` shim, but it is non-stateful and not universal), so the adapter targets Chat
Completions — exactly like `MiniMaxClient` and `OpenRouterClient` already do.

| Engine | Default base | Auth | `tools` | `response_format` | Notes |
|---|---|---|---|---|---|
| **Ollama** | `http://localhost:11434` | none — key field "required but ignored", dummy `ollama` | yes | yes (JSON mode / schema) | `tool_choice`, `n`, `user`, `logit_bias`, image **URLs** unsupported (base64 images only) |
| **llama.cpp** `llama-server` | `http://127.0.0.1:8080` | none unless `--api-key` | yes, best with `--jinja` | `json_object` **and** `json_schema`; can't combine with `grammar` | `model` field ignored unless `--alias`/router mode |
| **vLLM** | `http://localhost:8000` | none unless `--api-key` / `VLLM_API_KEY` | only with `--enable-auto-tool-choice --tool-call-parser <p>` | yes (xgrammar/guided decoding) | pydantic `extra="allow"` → unknown top-level fields are **warned, not rejected** |
| **SGLang** | `http://localhost:30000` | none unless `--api-key` | yes (`tools`, `tool_choice`, `parallel_tool_calls`) | yes, plus `regex` / `ebnf` | message roles are a strict `Literal` — see §2 |
| **LM Studio** | `http://localhost:1234` | none | yes | `json_schema` only (**no** `json_object`) | also has `/v1/responses` |

Consequence: **assume Chat Completions, assume nothing else.** Everything beyond
`model` / `messages` / `tools` / `response_format` / `max_tokens` has to be opt-in.

## 2. The `role: developer` trap

OpenAI's Responses API (what `CoachOrchestrator` builds) puts the per-turn context in a
`developer` message. Chat Completions predates that role, and the local engines disagree:

- **SGLang** validates roles against a pydantic `Literal`. Current `main` has
  `_GenericMessageRole = Literal["system","assistant","tool","function","developer","latest_reminder"]`
  with a `_normalize_role` validator that **raises** (→ HTTP 400) for anything else. `developer`
  was added later; released versions in the wild reject it outright.
- **vLLM** *rejects* it. Verified against a live vLLM **0.27.1** server:
  `{"role":"developer"}` returns **HTTP 422** — `Failed to deserialize the JSON body into the
  target type: messages[0]: unknown role: developer`. (Older vLLM parsed requests with pydantic
  models set to `extra="allow"` and did accept the role, passing it to the Jinja chat template,
  which usually has no `developer` branch either. Don't rely on the old behaviour.)
- **Ollama / llama.cpp / LM Studio** document only `system` / `user` / `assistant` / `tool`.

Even where the server accepts the role, the *chat template* usually can't render it. So the adapter
**always folds `developer` → `system`**, unconditionally, for every local backend. This is lossless
(the content is instructions either way) and is already what `MiniMaxClient.chatRole` does. Two of
the five engines are confirmed to hard-fail without it, so this is load-bearing, not defensive.

Second, related hazard: many local chat templates require the system message to be **first and
singular** and raise on a system turn after a user turn. `MiniMaxClient` appends
`CoachResponseSchema.promptInstruction` as a *trailing* system message; the local adapter instead
**merges all system messages into one leading system message**, so strict templates render.

## 3. Cleartext HTTP — three layers, and iOS does more of the work

A LAN box at `http://192.168.1.50:11434` has no TLS. App Transport Security blocks cleartext by
default, so every local request would fail before it left the device.

Unlike Android — whose Network Security Config can't express a CIDR allowlist, forcing an
app-wide `cleartextTrafficPermitted="true"` — iOS has an exception that means exactly what we
want. The restriction is three layers:

1. **`NSAllowsLocalNetworking`** in `PulseLoop/Info.plist`. It re-permits cleartext **only for
   local-network destinations**, so the platform keeps enforcing HTTPS for everything else. This
   is deliberately *not* `NSAllowsArbitraryLoads`. Every cloud provider endpoint in the app is a
   hardcoded `https://` constant and is unaffected. `NSLocalNetworkUsageDescription` is set
   alongside it, since talking to a LAN device triggers the iOS Local Network permission prompt.
2. **`LocalEndpoint.validate`** refuses a plaintext `http://` URL whose host could be on the
   public internet. ATS would refuse it too, but at request time, opaquely — this runs in the
   Settings field and can say *why*. Accepted: loopback, RFC1918, CGNAT `100.64/10`, link-local,
   and local-only names (`*.local`, `*.lan`, `*.home`, `*.internal`, `*.home.arpa`, Tailscale's
   `*.ts.net`, and single-label hosts like `http://nas:11434` — a box addressed by the name its
   router or mDNS hands out is an ordinary setup). `https://` hosts are unrestricted.
3. **`LocalHTTP` sends with redirects disabled** (`URLSessionTaskDelegate` returning `nil` from
   `willPerformHTTPRedirection`). Layer 2 vets the URL the user *typed*, not the one a request
   ends up on: a `307` from the validated LAN host to a public `http://` one would resend the
   coach's health-context POST body in the clear. Cloud providers keep the default session.

## 4. Timeouts

The cloud clients use `URLSession.shared` with a 60 s request timeout. A 30B model on CPU can
spend minutes on one tool-loop round, so `LocalHTTP` builds its own ephemeral session with a
user-configurable timeout (default 180 s, clamped to 10…1800 in Settings). Ephemeral rather than
shared for a second reason: it never writes a health-context response to a disk cache.

There is no retry. A slow local generation that times out has still *run* on the user's hardware,
and re-sending it would queue a second one behind the first.

## 5. Capability toggles, because local ≠ uniform

Three switches in Settings, because the same request body is fatal on one setup and required on
another:

- **Tool calling** (default on). vLLM 400s on `tools` without `--enable-auto-tool-choice`; small
  models hallucinate calls. Off ⇒ the adapter drops `tools` entirely and the coach answers from
  the prompt context alone.
- **Structured output**: `off` (default) / `json_object` / `json_schema`. Off relies on the
  injected `promptInstruction` plus the orchestrator's JSON-repair loop — the same path MiniMax
  uses, and the only one that works everywhere. `json_schema` sends
  `{type:"json_schema", json_schema:{name, strict, schema}}` from `CoachResponseSchema.schema`.
  LM Studio has no `json_object`; some llama.cpp builds error when `json_schema` meets `grammar`.
- **Max output tokens** (blank = omit). Local defaults vary from unlimited to a few hundred.
  Auto-detect fills this in from the server's reported **context window** — see §5b, and note it is
  a derivation, never a copy.

`reasoning` / `reasoning_effort` are **not** sent: only Ollama documents them, and vLLM/SGLang
would warn or 400. Anthropic `cache_control` and OpenRouter's `provider` block are likewise absent.

## 5a. Self-discovery — why the toggles are probed, not looked up

Asking the user to know whether their vLLM was started with `--enable-auto-tool-choice` is a bad
deal, and no metadata endpoint answers it: `/v1/models` describes the *model*, while the two
fields most likely to fail a turn (`tools`, `response_format`) are gated by *launch flags*. So
`LocalCapabilityProbe` sends the fields and reads the answer.

One press of **Detect server & configure** runs:

1. `GET /v1/models` — reachability, the model list, and the sole-model shortcut. This is the only
   step whose failure is fatal; nothing after it can be trusted if the server isn't there.
2. Engine identity, best-effort, from each engine's own info route (first hit wins):
   `GET /version` (vLLM), `/api/version` (Ollama), `/props` (llama.cpp), `/get_server_info`
   (SGLang), `/api/v0/models` (LM Studio). Deliberately *not* `owned_by` from `/v1/models` —
   vLLM says `vllm`, but Ollama says `library` and LM Studio says `organization_owner`, and any
   proxy rewrites all three. Cosmetic only: it drives the summary line, never the request body.
3. A **baseline** chat request carrying no optional fields at all.
4. A chat request carrying one throwaway tool.
5. A chat request carrying a minimal `response_format: json_schema`; only if that's refused is
   `json_object` tried.

Step 3 is what makes steps 4 and 5 readable. Without it, every rejection *of the request as a
whole* — a model id `/v1/models` lists but can't actually load (LM Studio with JIT loading off, a
model pulled between the two calls), a chat route that wants auth when the listing didn't, a broken
chat template — comes back as "tools: not supported" and persists `toolCalling = false`, costing
the coach all access to the user's data while blaming the wrong thing. If the baseline is refused
or inconclusive, steps 4 and 5 are skipped and both settings are left exactly as they were.

Classification rule: **4xx means the server refused the field** (vLLM answers `400` for a disabled
tool parser and `422` for a field its deserializer doesn't know, so the status itself carries no
extra meaning) → `NO`. A 5xx or a transport failure says nothing about the capability → `UNKNOWN`,
and the setting is **left at its default rather than switched off**, with a note explaining why.
Tool calling in particular only ever turns off on an explicit refusal — an inconclusive probe must
not silently strip the coach of its ability to read the user's data.

**A suggestion only overwrites a stored setting when the probe reached a verdict.** Detect is also
how you refresh the model list, so it gets pressed on setups that already work, and the safe
defaults above (tools ON, structured OFF) are right for a first run and wrong for a re-detect:
a user who turned tools off by hand for a vLLM server without `--enable-auto-tool-choice` would
otherwise have them switched back on by a press meant to do something else, and every turn would
`400`. Same for Max tokens — a server that reports no context window yields `0`, which means "not
detected", not "clear what the user typed".

Probes 3–5 use `max_tokens: 8` and a two-character prompt, and a minimal schema rather than the
coach's own (a large schema risks a rejection *about the schema* being read as "unsupported"). The
timeout is 120 s because on Ollama/LM Studio the first probe also pays for paging the model in.

The probe never picks a model when several are served and none matches the current setting —
guessing would silently move a working setup onto a different model.

### 5b. Max tokens is derived from the context window, never copied from it

Every engine reports the model's context window, under its own name:

| Engine | Route | Field |
|---|---|---|
| vLLM | `/v1/models` | `max_model_len` (262144 on the reference server) |
| llama.cpp | `/v1/models`, `/props` | `n_ctx` as served, `n_ctx_train` as the model ceiling |
| LM Studio | `/api/v0/models` | `loaded_context_length`, `max_context_length` |
| Ollama | `POST /api/show` | `model_info["<arch>.context_length"]` |
| SGLang | `/get_model_info` | context length |

A context window is **prompt + completion**, so writing it straight into `max_tokens` is wrong in
a way that fails closed: the server checks `max_tokens` against what is *left* after the prompt and
rejects a request where the two overflow. The derivation instead reserves room for the prompt:

```
headroom  = context − PROMPT_RESERVE_TOKENS (6144)
suggested = min(headroom, MAX_SUGGESTED_TOKENS (32768))
headroom < 512  ⇒  leave Max tokens blank and warn
```

6144 is the measured coach prompt (3.1–3.3k input tokens for a plain turn on-device) doubled, so a
turn replaying history and feeding back tool results still fits. The 32768 cap keeps a 262k context
from becoming a licence for a runaway generation — a `coach_response` needs far less.

**The warning is the more valuable half.** Ollama ships a default `num_ctx` of **2048**, smaller
than the coach's own prompt: without detection the prompt is silently truncated and the model gets
blamed. Detecting context lets Settings say so, and point at the server-side fix (`num_ctx`,
llama.cpp `-c`, vLLM `--max-model-len`) rather than at a setting in the app.

### Measured on a real server (vLLM 0.27.1, Qwen3.8-27B-INT8)

| Probe | Result |
|---|---|
| `GET /v1/models` | `qwen3.8-27b-int8-w8a16-mtp`, `max_model_len` 262144 |
| `GET /version` | `{"version":"0.27.1"}` → engine identified |
| `tools` | HTTP 200 → supported |
| `response_format: json_schema` | HTTP 200 → supported |
| `max_model_len` | 262144 → Max tokens suggested as 32768 (capped) |
| `role: developer` | **HTTP 422, `unknown role: developer`** |

Also observed: with a reasoning parser enabled, vLLM returns the chain of thought in
`message.reasoning` (older builds: `reasoning_content`) and leaves `content` null until reasoning
finishes. The adapter reads neither field, so this is inert — but it means a `max_tokens` low
enough to truncate mid-reasoning yields no content at all, which the client reports as an
out-of-tokens error rather than a bare "no output".

## 6. Changes in this repo

New, all under `PulseLoop/Coach/Local/` (the target uses a file-system-synchronized group, so no
`project.pbxproj` edit is needed):

| File | What it is |
|---|---|
| `LocalEndpoint.swift` | URL normalize/validate + the private-host rule (§3 layer 2) |
| `LocalHTTP.swift` | The no-redirect, long-timeout session (§3 layer 3, §4) |
| `LocalModelCatalog.swift` | `GET /v1/models` → the model picker, plus per-engine context windows |
| `LocalCapabilityProbe.swift` | Engine identity + baseline/tools/response_format probes (§5a) |
| `LocalOpenAICompatClient.swift` | The `ResponsesClient` adapter — Responses → Chat Completions |
| `LocalLLMKeychainStore.swift` | The **optional** API key |

Modified:

| File | Change |
|---|---|
| `Coach/Config/CoachSettings.swift` | `.localOpenAICompat` mode, `LocalStructuredOutput`, six `local*` fields + tolerant decode |
| `Coach/Config/CoachClientResolver.swift` | Builds the client; readiness is `validate(baseURL) == nil` |
| `Coach/Config/CoachFeatureFlags.swift` | `coachEnabled` / `effectiveModel` / `statusLine` for the new mode |
| `Coach/Config/CoachSettingsSection.swift` | The Local server + Request options groups, and Detect |
| `Views/SettingsView.swift` | Provider summary row |
| `Info.plist` | `NSAllowsLocalNetworking` + `NSLocalNetworkUsageDescription` (§3 layer 1) |

`PulseLoopTests/LocalLLMTests.swift` covers all four pure units — 43 tests.

### Readiness gate

Every other provider is ready when its key exists. This one is ready when
`LocalEndpoint.validate(baseURL) == nil` — the key is optional on every engine in scope, and the
Settings field persists as the user types, so a non-empty check would flip the coach to "Active"
on the first character typed and then fail every turn with the URL error already shown inline.

`CoachFeatureFlags.hasAPIKey` carries that sentinel for the local mode; it is not a key.

### What is not verified

No hardware/server run yet. The honest test is: start Ollama or llama.cpp on the LAN, point the
app at it, press **Detect server & configure**, and hold a real coach conversation with tools on.
Everything in this port is unit-tested at the pure level and compiles clean, which is not the
same thing.

## Sources

- [Ollama — OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility)
- [llama.cpp — server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- [vLLM — Tool Calling](https://docs.vllm.ai/en/stable/features/tool_calling/)
- [vLLM — `entrypoints/openai/protocol.py`](https://github.com/vllm-project/vllm/blob/v0.11.0/vllm/entrypoints/openai/protocol.py) (`OpenAIBaseModel`, `extra="allow"`)
- [SGLang — `entrypoints/openai/protocol.py`](https://github.com/sgl-project/sglang/blob/main/python/sglang/srt/entrypoints/openai/protocol.py) (`_GenericMessageRole`, `_normalize_role`)
- [SGLang — OpenAI APIs: Completions](https://docs.sglang.io/docs/basic_usage/openai_api_completions)
- [LM Studio — OpenAI compatibility endpoints](https://lmstudio.ai/docs/developer/openai-compat)
