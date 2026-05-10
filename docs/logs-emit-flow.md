# Logs emit flow

This document traces what happens from `Logger.emit` through to wire transmission.
Items marked **(spec)** are mandated by the [OTel Logs SDK spec](https://opentelemetry.io/docs/specs/otel/logs/sdk/);
unmarked items are implementation choices.

## Overview

```
Logger.emit(severity, body, options)
  └─ ReadWriteLogRecord (stack, borrowed data)          ← one, shared by all processors  [impl]
       ├─ Processor[0].onEmit(rw_record)                ← mutate, return                 [spec]
       ├─ Processor[1].onEmit(rw_record)                ← sees Processor[0]'s mutations  [spec]
       └─ Processor[N].onEmit(rw_record)                ← exporting processor
            ├─ toReadable() → ReadableLogRecord         ← immutable snapshot, owned copy [impl]
            └─ exporter.exportLogs(readable)            ← exporter receives ReadableLogRecord [spec]
                 └─ ... send → readable.deinit
  └─ (ReadWriteLogRecord freed when emit returns)       [impl]
```

## Step-by-step

### 1. `Logger.emit` — stack allocation, borrowed data *(impl)*

`emit` stack-allocates a `ReadWriteLogRecord` and stores caller-provided slices directly as
pointers (no copy):

- `log_record.body = body` — points into the caller's string
- `log_record.severity_text = options.severity_text` — same
- `options.attributes` are appended into `log_record.attributes`
  (`ArrayListUnmanaged(Attribute)`) via `setAttribute`, which copies the `Attribute` struct
  (key slice header + value union) but does **not** dupe the pointed-to bytes

At this point all string data is still owned by the caller.

### 2. `LogRecordProcessor.onEmit` — pipeline *(spec)*

Processors are a chain: each receives the same `*ReadWriteLogRecord` in registration order
and may mutate it — the spec mandates that *"logRecord mutations MUST be visible in next
registered processors"* and that `OnEmit` *"is called synchronously on the thread that
emitted the LogRecord"*. The last processor in the chain is typically an exporting processor
(`SimpleLogRecordProcessor`, `BatchingLogRecordProcessor`), which calls `toReadable` to
obtain an immutable snapshot and forwards it to its exporter. Earlier processors just mutate
and return.

### 3. `ReadWriteLogRecord.toReadable` — ownership transfer *(impl)*

The spec requires exporters to receive a `ReadableLogRecord` but does not prescribe how the
conversion happens. This SDK converts inside the exporting processor's `onEmit` via
`toReadable`, which deep-copies all borrowed data:

| Field | Handling |
|---|---|
| `body` | `allocator.dupe(u8, b)` |
| `severity_text` | `allocator.dupe(u8, text)` |
| `attributes` (string values) | `allocator.dupe(u8, s)` per string value and keys |
| `attributes` (non-string values) | copied by value (no heap) |
| `structured_body` (string values) | `allocator.dupe(u8, s)` per string value; keys are shallow-copied |
| `trace_id`, `span_id` | copied by value (`[16]u8` / `[8]u8` arrays) |
| `resource` | shallow pointer copy (resource is owned by the provider, outlives all records) |
| `scope` | copied by value |

After `toReadable`, the `ReadableLogRecord` owns all its data. The caller's strings (body,
severity_text, attribute values) only need to remain valid until `emit` returns.

### 4a. `SimpleLogRecordProcessor` — synchronous export *(spec names this processor)*

```zig
const readable = log_record.toReadable(allocator);
defer readable.deinit(allocator);
exporter.exportLogs([readable]);
```

The `ReadableLogRecord` lives on the stack of `onEmit`. The exporter receives it and must
complete synchronously — it cannot store pointers to the record's data past the call.

### 4b. `BatchingLogRecordProcessor` — deferred export *(spec names this processor)*

`toReadable` is still called inside `onEmit` (synchronously, while the `ReadWriteLogRecord`
is still valid), and the resulting `ReadableLogRecord` is pushed onto an internal
`LogRecordQueue`. It lives there until `exportBatch` pops it on the background task, calls
`exporter.exportLogs`, then calls `readable.deinit`.

### 5. `OTLPExporter.exportLogs` — conversion to protobuf

`logsToOTLPRequest` walks the `ReadableLogRecord` slice and allocates protobuf structs:

- `body` → `pbcommon.AnyValue { .string_value = body }` (string slice reused, not duped)
- `structured_body` → `pbcommon.AnyValue { .kvlist_value = ... }` (new `ArrayListUnmanaged(KeyValue)`)
- `attributes` / `resource` → `pbcommon.KeyValue` list (string slices reused)
- `trace_id` / `span_id` → copied into `[]const u8` fields via `allocator.dupe`

The OTLP request owns the `ArrayList` allocations. `otlp.Export` serialises to bytes and
sends. `cleanupRequest` frees the request's heap allocations. The `ReadableLogRecord` is
freed by the processor after `exportLogs` returns.

## Lifetime summary

| Data | Must stay valid until |
|---|---|
| `body` passed to `emit` | `emit` returns |
| `options.severity_text` | `emit` returns |
| `options.attributes` slice and its string values | `emit` returns |
| `options.span_context` | `emit` returns (copied by value) |
| `ReadableLogRecord` | `exportLogs` returns (Simple) or `exportBatch` returns (Batching) |
| OTLP protobuf request | `cleanupRequest` |

## Known shallow copies

- **Attribute keys** in `toReadable`: copied as slice headers. Keys from semconv libraries
  are comptime literals (safe). Runtime-constructed keys (e.g. `allocPrint`) must outlive
  `emit` — same contract as `body`.
- **`resource`** pointer: the provider owns the resource slice and it outlives all records.
- **`scope`** strings: `InstrumentationScope` fields are string literals; copied by value.
