console.log("sizes body");
export enum Tone { Dark = 3, Light = 7 }
export function toneName(t: Tone): string { return t == Tone.Light ? "light" : "dark"; }
