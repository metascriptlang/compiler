import type { Label } from "./types";
export interface Options { label: Label; enabled?: boolean; }
export enum Color { Red, Blue }
export function greeting(): string { return "hello"; }
export function read(options: Options): string { return options.label.text; }
export async function later(): Promise<string> { return "later"; }
export default 7;
