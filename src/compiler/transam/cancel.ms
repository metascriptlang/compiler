// Trans-Am Cancellation — version-based query cancellation for LSP
//
// LSP calls requestCancel() on user keystroke. Long-running queries
// periodically call checkCancel() to self-abort. Version only increments,
// never resets (Salsa pattern). No atomics needed (single-threaded).
//
// CancelCtx type lives in checker/context.ms (single source of truth).
// transam→checker dependency is already established (CheckerContext, etc.).

import { CancelCtx } from "../../checker/context";

// ===== Cancellation Context =====

export function createCancelContext(): CancelCtx {
	return { version: 0, cancelled: false };
}

// ===== Cancellation API =====

// Capture version at query start
export function getCancelVersion(ctx: CancelCtx): number {
	return ctx.version;
}

// Check if query should abort (version changed since start)
export function checkCancel(ctx: CancelCtx, startingVersion: number): boolean {
	return ctx.version !== startingVersion || ctx.cancelled;
}

// Request cancellation (called by LSP on keystroke)
export function requestCancel(ctx: CancelCtx): void {
	ctx.version = ctx.version + 1;
	ctx.cancelled = true;
}

// Reset after handling cancellation
export function resetCancel(ctx: CancelCtx): void {
	ctx.cancelled = false;
}

// ===== Tests =====
test "initial state is not cancelled" {
	const ctx = createCancelContext();
	assert ctx.version === 0;
	assert !ctx.cancelled;
}

test "checkCancel false when version matches" {
	const ctx = createCancelContext();
	const ver = getCancelVersion(ctx);
	assert !checkCancel(ctx, ver);
}

test "requestCancel increments version" {
	const ctx = createCancelContext();
	requestCancel(ctx);
	assert ctx.version === 1;
	assert ctx.cancelled;
}

test "checkCancel true after requestCancel" {
	const ctx = createCancelContext();
	const ver = getCancelVersion(ctx);
	requestCancel(ctx);
	assert checkCancel(ctx, ver);
}

test "resetCancel clears flag but keeps version" {
	const ctx = createCancelContext();
	requestCancel(ctx);
	assert ctx.version === 1;
	resetCancel(ctx);
	assert !ctx.cancelled;
	assert ctx.version === 1;
}

test "multiple cancels increment version" {
	const ctx = createCancelContext();
	requestCancel(ctx);
	resetCancel(ctx);
	requestCancel(ctx);
	assert ctx.version === 2;
}
