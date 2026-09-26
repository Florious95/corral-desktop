# Contracts v0.1

`ContractVersion.string` is the native API revision (`0.1`); it is independent of Protocol v1 (`ProtocolV1.version == 1`). This is a client-contract change only and does not change the server wire version.

## Endpoint and protocol

- `ApprovedEndpoint` admits only loopback port `9919` and the canonical `/ws` path; `localhost` canonicalizes to `127.0.0.1`. `9900`, all non-loopback hosts, malformed IPv6 brackets, credentials, query/fragment, and other paths are rejected. Its stored validated URL is readable without reconstruction or a trap, including `[::1]`.
- Binary frames are a sum type. References are nonempty opaque UTF-8 values (at most 255 bytes). Scrollback always carries `req_id:u32`, signed `from_line:i32`, and positive `line_count:u32`; the 1 MiB client policy applies to ANSI bytes, excluding the 12-byte history header.
- JSON control messages use explicit `{v,type,payload}` mapping. Commands and server controls are separate types; synthesized enum Codable is not a wire codec. V1 request IDs are `UInt32`; listing `seq` remains a separate `UInt64`. The codec ignores unknown JSON fields and rejects unknown types/states.
- `SessionLink.connect` completes only after authentication is ready. One receive stream and one FIFO sender belong to each link. Each event carries device, link-instance, connection-epoch, local receive ordinal, and wire-byte count. Stream budgets are explicit; a full stream must backpressure or terminate rather than silently drop ANSI. Socket-write receipts and server `input_ack` are distinct; uncertain side effects are not replayed.

## Terminal and stage

- Cells carry engine-provided grapheme clusters and explicit one/two-column spans; wide continuation cells are distinct. Snapshot validity checks cell count, continuation pairing, cursor bounds, and wrap-pending state. Column width is never inferred from `String.count`.
- Terminal input and engine effects use separate routes. Applying server bytes may produce local effects; an effect sink has no SessionLink uplink. User input is encoded/sent separately and is not locally echoed by the VT engine.
- Stage, pane, and device-scoped session identities are explicit. A stage submits one complete visible-pane batch with layout/metrics/content generations and a frame receipt. Only a completed visible receipt for the current layout/metrics and no-newer-than-parsed content advances presentation progress. Hidden stages remain dirty; application focus is not visibility. In-flight frames are bounded by the renderer contract.

## Atlas and composition

- Glyph keys represent shaped glyph IDs plus font-instance/variation/raster identity. Locations name a device resource and generation; absence is optional/error, never a zero-coordinate sentinel.
- Atlas work follows `reserve → publish → lease → retire → reclaim`. Budget reservation is atomic across GPU bytes, pages, and CPU shadow bytes. Retired resources remain alive while frame leases refer to them and cannot be reused early.
- `CorralProtocol`, `CorralServices`, `CorralMetalTerminal`, and `CorralUI` depend only on `CorralContracts`. Concrete implementations and the complete graph are assembled by `CorralApp`.

These are interface laws, not claims that a WebSocket transport, VT kernel, Metal renderer, or GPU retirement implementation has already been integrated or physically measured.
