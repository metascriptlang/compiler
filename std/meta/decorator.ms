import { Node } from "./node";

export interface DecoratorMetadata {
	keys: string[];
	values: Node[];
}

export interface DecoratorAccess {
	get: (receiver: Node) => Node;
	set: (receiver: Node, value: Node) => Node;
	has: (receiver: Node) => Node;
}

export interface DecoratorContext {
	kind: string;
	name: string;
	static: boolean;
	private: boolean;
	access: DecoratorAccess;
	addInitializer: (statement: Node) => void;
	metadata: DecoratorMetadata;
}

export type ClassDecoratorContext = DecoratorContext;
export type ClassMethodDecoratorContext = DecoratorContext;
export type ClassFieldDecoratorContext = DecoratorContext;

export function metadataSet(m: DecoratorMetadata, key: string, value: Node): void {
	for (let i = 0; i < m.keys.length; i += 1) {
		if (m.keys[i] == key) {
			m.values[i] = value;
			return;
		}
	}
	m.keys.push(key);
	m.values.push(value);
}

export function metadataHas(m: DecoratorMetadata, key: string): boolean {
	for (const k of m.keys) {
		if (k == key) return true;
	}
	return false;
}

export function metadataGet(m: DecoratorMetadata, key: string): Node | null {
	for (let i = 0; i < m.keys.length; i += 1) {
		if (m.keys[i] == key) return m.values[i];
	}
	return null;
}
