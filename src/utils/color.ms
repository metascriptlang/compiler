import { env } from "std/process";

let enabled = true;
let initialized = false;

function isEnabled(): boolean {
	if (!initialized) {
		initialized = true;
		if (env.get("NO_COLOR").length > 0) enabled = false;
	}
	return enabled;
}

export function setColorEnabled(on: boolean): void {
	enabled = on;
	initialized = true;
}

function wrap(code: string, text: string): string {
	if (!isEnabled()) return text;
	return `\x1b[${code}m${text}\x1b[0m`;
}

export function bold(text: string): string {
	return wrap("1", text);
}

export function dim(text: string): string {
	return wrap("2", text);
}

export function underline(text: string): string {
	return wrap("4", text);
}

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

export function error(text: string): string {
	return bold(red(text));
}

export function success(text: string): string {
	return bold(green(text));
}

export function path(text: string): string {
	return underline(cyan(text));
}

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

test "setColorEnabled switches the escape codes on and off" {
	setColorEnabled(true);
	assert red("x") == "\x1b[31mx\x1b[0m";
	setColorEnabled(false);
	assert red("x") == "x";
	setColorEnabled(true);
}
