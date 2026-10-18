import { Session } from "./session";
export interface Model { session: Session }
export function createModel(): Model { return { session: new Session() }; }
