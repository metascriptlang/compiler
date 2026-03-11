// Terminal Color Utilities — ANSI escape code helpers for CLI output
//
// Usage: red("error"), bold(green("ok")), dim("hint")
// Composable: bold(red("fatal")) → "\x1b[1m\x1b[31mfatal\x1b[0m\x1b[0m"
// Honors NO_COLOR env var (https://no-color.org) and --colors flag

import { getEnv } from "std/process";


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
		const noColor = getEnv("NO_COLOR");
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

export function italic(text: string): string {
	return wrap("3", text);
}

export function underline(text: string): string {
	return wrap("4", text);
}

export function strikethrough(text: string): string {
	return wrap("9", text);
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

export function magenta(text: string): string {
	return wrap("35", text);
}

export function cyan(text: string): string {
	return wrap("36", text);
}

export function white(text: string): string {
	return wrap("37", text);
}

export function gray(text: string): string {
	return wrap("90", text);
}

// ===== Bright foreground colors =====

export function brightRed(text: string): string {
	return wrap("91", text);
}

export function brightGreen(text: string): string {
	return wrap("92", text);
}

export function brightYellow(text: string): string {
	return wrap("93", text);
}

export function brightBlue(text: string): string {
	return wrap("94", text);
}

export function brightCyan(text: string): string {
	return wrap("96", text);
}

// ===== Background colors =====

export function bgRed(text: string): string {
	return wrap("41", text);
}

export function bgGreen(text: string): string {
	return wrap("42", text);
}

export function bgYellow(text: string): string {
	return wrap("43", text);
}

export function bgBlue(text: string): string {
	return wrap("44", text);
}

// ===== Semantic helpers (CLI-oriented) =====

export function error(text: string): string {
	return bold(red(text));
}

export function success(text: string): string {
	return bold(green(text));
}

export function warning(text: string): string {
	return bold(yellow(text));
}

export function info(text: string): string {
	return bold(cyan(text));
}

export function hint(text: string): string {
	return dim(text);
}

export function label(text: string): string {
	return bold(white(text));
}

export function path(text: string): string {
	return underline(cyan(text));
}

// ===== Strip ANSI codes =====

export function stripAnsi(text: string): string {
	let result = "";
	let i = 0;
	while (i < text.length) {
		if (text.slice(i, i + 2) === "\x1b[") {
			// Skip until 'm'
			i += 2;
			while (i < text.length && text.slice(i, i + 1) !== "m") {
				i += 1;
			}
			i += 1;
		} else {
			result = result + text.slice(i, i + 1);
			i += 1;
		}
	}
	return result;
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
	const result = dim(gray("faded"));
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

test "warning is bold yellow" {
	const w = warning("warn");
	assert w.length > 4;
}

test "info is bold cyan" {
	const inf = info("note");
	assert inf.length > 4;
}

test "hint is dim" {
	const h = hint("maybe");
	assert h.length > 5;
}

test "path is underline cyan" {
	const p = path("/foo/bar");
	assert p.length > 8;
}

test "strip removes codes" {
	const colored = red("hello");
	const stripped = stripAnsi(colored);
	assert stripped === "hello";
}

test "strip handles nested" {
	const colored = bold(red("x"));
	const stripped = stripAnsi(colored);
	assert stripped === "x";
}

test "strip preserves plain text" {
	const stripped = stripAnsi("plain");
	assert stripped === "plain";
}
