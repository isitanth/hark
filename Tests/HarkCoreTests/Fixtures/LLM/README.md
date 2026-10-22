# LLM fixtures

Recorded 2026-09-28 from MTPLX 2.12 serving `mtplx-bonsai-2-27b-optimized-speed` on this Mac
(`http://127.0.0.1:8002/v1`), by a scratch script that read the API key from the Keychain and sent it only in the
`Authorization` header. The bodies are byte for byte what the server sent; no request headers were recorded.

- `summary-fr.sse`: "résume ce texte", `enable_thinking: false`, temperature 0.3, max_tokens 200. A role chunk,
  empty `mtplx_progress` deltas, content deltas, the finish chunk (`stop`) with `usage`, `mtplx_stats` and
  `timings`, then `[DONE]`.
- `thinking-on.sse`: thinking at the server default, max_tokens 48: `reasoning_content` deltas only, finish `length`.
- `long-prefill.sse`: a selection of about 2,400 prompt tokens: a `: keep-alive` comment during the prefill.
- `models.json`: `GET /v1/models`.
- `unauthorized-401.json`: the 401 body for a missing key (a wrong key gives the same body).

Written by hand, because MTPLX could not be made to send them (it serves an unknown model id and clamps a bad
`max_tokens` rather than refusing):
- `error-in-stream.sse`: the first chunks of `summary-fr.sse`, then an `{"error": …}` chunk and no `[DONE]`.
- `server-error-500.json`: an OpenAI-style error body with a message, for a status other than 401.

Anthropic's Messages API, 2026-10-12:
- `anthropic-unauthorized-401.json`: recorded from `GET https://api.anthropic.com/v1/models` with a made-up key in
  `x-api-key`; the body is what the server sent.
- Written by hand from the documented stream format, since no key was used to record them: `anthropic-stream.sse`
  (`message_start` with the input tokens, a thinking block with only a signature as `display: omitted` sends it,
  `ping`, three `text_delta`, `message_delta` with `end_turn` and the output tokens, `message_stop`),
  `anthropic-refusal.sse` (`stop_reason: refusal` before any text), `anthropic-error-in-stream.sse` (one word, then
  an `overloaded_error` event), `anthropic-overloaded-529.json` and `anthropic-models.json`.

Visual Context (M11), 2026-10-22, written by hand from the servers' sources and documentation (report a5 of the M11
plan, §1, §2 and §5), since no server was asked to refuse an image:
- `models-no-vision.json`: `models.json` with `supports_vision: false` and `modalities.input` `["text"]`, as MTPLX
  lists a pack without a vision tower.
- `llamacpp-models.json`: llama.cpp's `GET /v1/models` for a text-only model, `architecture.input_modalities`
  (llama.cpp tools/server/server-context.cpp).
- `anthropic-models.json` gained `capabilities.image_input` and `pdf_input` per entry
  (platform.claude.com/docs/en/api/models/list).
- Refusals of a request that carried an image (report a5, §1 and §5): `no-vision-400.json` (MTPLX, a pack with no
  vision tower), `vision-ar-mode-400.json` (MTPLX in AR mode), `openai-no-vision-400.json` (OpenAI's wording),
  `llamacpp-no-mmproj-500.json` (llama.cpp without its mmproj, tools/server/server-common.cpp),
  `mlxlm-text-only-404.json` (mlx-lm's server, a bare string `error`), `vllm-not-multimodal-400.json` (vLLM),
  `anthropic-image-too-large-400.json` (an image over 10 MB, wording assumed from the vision documentation) and
  `probable-400.json` (a 400 in none of the words Hark recognizes).
