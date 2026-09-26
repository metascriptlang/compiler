export enum EvKind { Click, Key }
export interface ClickEv { kind: EvKind.Click; x: int32; }
export interface KeyEv { kind: EvKind.Key; code: int32; }
export type Ev = ClickEv | KeyEv;
