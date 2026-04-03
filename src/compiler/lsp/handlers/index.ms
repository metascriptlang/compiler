// LSP Handlers Hub — re-exports public API from sub-modules.
// External callers import from "./handlers" which resolves here.

export { CompletionCache, createCompletionCache } from "./shared";
export { buildDiagnosticsJson, buildTransitiveDiagnosticsWire, recordImportsForFile, resetFormatOptions } from "./diagnostics";
export { prebuildCompletionCache } from "./completion";
export { lspDispatch, publishPendingDiagnostics } from "./lifecycle";
