export let events: string = "";
export function record(value: string): void { events = events + value; }
