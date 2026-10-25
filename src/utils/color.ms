// Terminal Color Utilities — ANSI escape code helpers for CLI output
//
// Usage: red("error"), bold(green("ok")), dim("hint")
// Composable: bold(red("fatal")) → "\x1b[1m\x1b[31mfatal\x1b[0m\x1b[0m"
// Honors NO_COLOR env var (https://no-color.org) and --colors flag

import { env } from "std/process";


// ===== Color enable/disable =====

// Wrap in interface to avoid DRC module-level let string reassignment bug
interface ColorState {
	enabled: boolean;
	initialized: boolean;
}

const state: ColorState = { enabled: true, initialized: false };

function isEnabled(): boolean {
	if (!state.initialized) {
		state.initialized = true;
		// Respect NO_COLOR (https://no-color.org)
		const noColor = env.get("NO_COLOR");
		if (noColor.length > 0) {
			state.enabled = false;
		}
	}
	return state.enabled;
}

// Set color mode explicitly (called from CLI --colors flag)
export function setColorEnabled(enabled: boolean): void {
	state.enabled = enabled;
	state.initialized = true;
}

// ===== Core wrap function =====

function wrap(code: string, text: string): string {
	if (!isEnabled()) return text;
	return `\x1b[${code}m${text}\x1b[0m`;
}

// ===== Style modifiers =====

export function bold(text: string): string {
	return wrap("1", text);
}

export function dim(text: string): string {
	return wrap("2", text);
}

export function underline(text: string): string {
	return wrap("4", text);
}

// ===== Foreground colors =====

export function red(text: string): string {
	return wrap("31", text);
}

export function green(text: string): string {
	return wrap("32", text);
}

export function yellow(text: string): string {
	return wrap("33", text);
}

export function blue(text: string): string {
	return wrap("34", text);
}

export function cyan(text: string): string {
	return wrap("36", text);
}

// ===== Semantic helpers (CLI-oriented) =====

export function error(text: string): string {
	return bold(red(text));
}

export function success(text: string): string {
	return bold(green(text));
}

export function path(text: string): string {
	return underline(cyan(text));
}

// ===== Tests =====
test "red wraps text" {
	const result = red("hello");
	assert result.length > 5;
}

test "bold wraps text" {
	const result = bold("hello");
	assert result.length > 5;
}

test "green wraps text" {
	const result = green("ok");
	assert result.length > 2;
}

test "bold + red composes" {
	const result = bold(red("error"));
	assert result.length > 10;
}

test "dim composes" {
	const result = dim(red("faded"));
	assert result.length > 5;
}

test "error is bold red" {
	const e = error("fail");
	assert e.length > 4;
}

test "success is bold green" {
	const s = success("pass");
	assert s.length > 4;
}

test "path is underline cyan" {
	const p = path("/foo/bar");
	assert p.length > 8;
}
