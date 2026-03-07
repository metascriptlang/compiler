// Utility module for multi-module test

export enum Level { Debug, Info, Warn, Error }

export interface Message {
	level: Level;
	text: string;
}

export function makeMsg(level: Level, text: string): Message {
	return { level: level, text: text };
}

export function levelName(lv: Level): string {
	return match (lv) {
		Level.Debug => "DEBUG",
		Level.Info => "INFO",
		Level.Warn => "WARN",
		Level.Error => "ERROR",
	};
}

export function formatMsg(msg: Message): string {
	return "[" + levelName(msg.level) + "] " + msg.text;
}

export function maxNum(a: number, b: number): number {
	if (a > b) return a;
	return b;
}

export function minNum(a: number, b: number): number {
	if (a < b) return a;
	return b;
}

export function clamp(val: number, lo: number, hi: number): number {
	return maxNum(lo, minNum(val, hi));
}

export function repeatStr(s: string, n: number): string {
	let result = "";
	let i = 0;
	while (i < n) {
		result = result + s;
		i += 1;
	}
	return result;
}

export function padLeft(s: string, width: number, ch: string): string {
	if (s.length >= width) return s;
	return repeatStr(ch, width - s.length) + s;
}
