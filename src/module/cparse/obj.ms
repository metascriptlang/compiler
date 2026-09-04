// cparse — Top-level declarations (headers-only subset)

import { CType } from "./type";

export enum ObjKind {
	Function,        // extern function prototype
	Variable,        // extern variable
	TypedefName,     // typedef T Name;
	TagStruct,       // struct Name { ... };
	TagUnion,
	TagEnum,
	EnumConstant,    // enumerator from an enum { A = 1, B = 2 }
}

export interface Obj {
	kind: ObjKind;
	name: string;
	type: CType;
	isStatic: boolean;
	isExtern: boolean;
	isDefinition: boolean;   // function with body? variable with initializer?
	// For EnumConstant only
	enumValue: int64;
	// Source location of declaration
	file: string;
	line: int32;
}
