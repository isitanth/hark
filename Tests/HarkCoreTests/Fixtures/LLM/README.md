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
