// Raiser VM — Computed goto dispatch loop
// Compiled via @include("dispatch.c") in vm.ms
//
// Self-contained type definitions matching MetaScript-generated C layout.
// Must be kept in sync with bytecode.ms, value.ms, module.ms, vm.ms.
//
// Returns: 0.0 = halted normally, 1.0 = unhandled opcode (vm->ip set)

#include "dispatch.h"
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// --- Opcode values (must match RaiserOpcode enum in bytecode.ms) ---
#define OP_LOAD_CONST  0
#define OP_MOVE        1
#define OP_LOAD_NIL    2
#define OP_ADD_I64     3
#define OP_SUB_I64     4
#define OP_MUL_I64     5
#define OP_DIV_I64     6
#define OP_MOD_I64     7
#define OP_NEG_I64     8
#define OP_BEQ_I64     9
#define OP_BNE_I64     10
#define OP_BLT_I64     11
#define OP_BLE_I64     12
#define OP_BGT_I64     13
#define OP_BGE_I64     14
#define OP_JUMP        15
#define OP_CALL        16
#define OP_RET         17
#define OP_HALT        18
#define OP_PRINT       19
#define OP_COUNT       20

// --- Value kind (must match RaiserValueKind in value.ms) ---
#define VK_NIL   0
#define VK_INT   2

// --- Struct layouts (must match generated _common.h) ---

#ifndef _RAISER_DISPATCH_TYPES
#define _RAISER_DISPATCH_TYPES

typedef struct _RD_Inst {
	uint8_t op;
	double a;
	double b;
	double c;
} _RD_Inst;

typedef struct _RD_Val {
	uint8_t kind;
	double intVal;
	double floatVal;
} _RD_Val;

// MS_ARRAY(T*) = struct { int len; struct { size_t cap; T* data[]; }* p; }
typedef struct { size_t cap; _RD_Inst* data[]; } _RD_InstPayload;
typedef struct { int len; _RD_InstPayload* p; } _RD_InstArr;

typedef struct { size_t cap; _RD_Val* data[]; } _RD_ValPayload;
typedef struct { int len; _RD_ValPayload* p; } _RD_ValArr;

typedef struct { size_t cap; struct _RD_Func* data[]; } _RD_FuncPayload;
typedef struct { int len; _RD_FuncPayload* p; } _RD_FuncArr;

// msString = struct { int len; struct { size_t cap; char data[]; }* p; }
typedef struct { size_t cap; char data[]; } _RD_StrPayload;
typedef struct { int len; _RD_StrPayload* p; } _RD_Str;

typedef struct { _RD_InstArr items; } _RD_CodeBuf;
typedef struct { _RD_ValArr values; } _RD_ConstPool;

typedef struct _RD_Func {
	_RD_Str name;
	_RD_CodeBuf* code;
	_RD_ConstPool* constants;
	double arity;
	double localsCount;
	double maxRegs;
} _RD_Func;

typedef struct { _RD_FuncArr items; } _RD_FuncList;

typedef struct {
	_RD_Str name;
	_RD_FuncList* functions;
	double entry;
} _RD_Module;

typedef struct { _RD_ValArr slots; } _RD_RegFile;

typedef struct {
	_RD_Module* mod;
	_RD_RegFile* regs;
	double ip;
	bool halted;
	_RD_Val* exitValue;
	_RD_Str output;
} _RD_VM;

#endif // _RAISER_DISPATCH_TYPES

// --- Computed goto dispatch ---
// RaiserVM is forward-declared in dispatch.h.
// Binary layout of _RD_VM matches the generated RaiserVM exactly.

double raiser_dispatch_impl(RaiserVM* vm_opaque) {
	_RD_VM* vm = (_RD_VM*)vm_opaque;

	// Extract entry function
	int entry_idx = (int)vm->mod->entry;
	_RD_Func* entry = vm->mod->functions->items.p->data[entry_idx];

	// Hot state: instruction array, constants, registers
	_RD_Inst** code = entry->code->items.p->data;
	int code_len = entry->code->items.len;
	_RD_Val** consts = entry->constants->values.p->data;
	_RD_Val** regs = vm->regs->slots.p->data;
	int ip = (int)vm->ip;

	// Computed goto dispatch table — one label per opcode
	static void* dispatch_table[OP_COUNT] = {
		&&op_load_const,  // 0
		&&op_move,        // 1
		&&op_load_nil,    // 2
		&&op_add_i64,     // 3
		&&op_sub_i64,     // 4
		&&op_mul_i64,     // 5
		&&op_div_i64,     // 6
		&&op_mod_i64,     // 7
		&&op_neg_i64,     // 8
		&&op_beq_i64,     // 9
		&&op_bne_i64,     // 10
		&&op_blt_i64,     // 11
		&&op_ble_i64,     // 12
		&&op_bgt_i64,     // 13
		&&op_bge_i64,     // 14
		&&op_jump,        // 15
		&&op_call,        // 16
		&&op_ret,         // 17
		&&op_halt,        // 18
		&&op_print,       // 19
	};

	#define DISPATCH() do { \
		if (ip < 0 || ip >= code_len) goto done; \
		goto *dispatch_table[code[ip]->op]; \
	} while(0)

	DISPATCH();

	// === Memory ===

	op_load_const: {
		_RD_Inst* inst = code[ip]; ip++;
		int bx = (int)(inst->b * 256.0 + inst->c);
		_RD_Val* src = consts[bx];
		_RD_Val* dst = regs[(int)inst->a];
		dst->kind = src->kind;
		dst->intVal = src->intVal;
		dst->floatVal = src->floatVal;
		DISPATCH();
	}

	op_move: {
		_RD_Inst* inst = code[ip]; ip++;
		_RD_Val* src = regs[(int)inst->b];
		_RD_Val* dst = regs[(int)inst->a];
		dst->kind = src->kind;
		dst->intVal = src->intVal;
		dst->floatVal = src->floatVal;
		DISPATCH();
	}

	op_load_nil: {
		_RD_Inst* inst = code[ip]; ip++;
		_RD_Val* dst = regs[(int)inst->a];
		dst->kind = VK_NIL;
		dst->intVal = 0.0;
		dst->floatVal = 0.0;
		DISPATCH();
	}

	// === i64 Arithmetic ===

	op_add_i64: {
		_RD_Inst* inst = code[ip]; ip++;
		regs[(int)inst->a]->kind = VK_INT;
		regs[(int)inst->a]->intVal = regs[(int)inst->b]->intVal + regs[(int)inst->c]->intVal;
		DISPATCH();
	}

	op_sub_i64: {
		_RD_Inst* inst = code[ip]; ip++;
		regs[(int)inst->a]->kind = VK_INT;
		regs[(int)inst->a]->intVal = regs[(int)inst->b]->intVal - regs[(int)inst->c]->intVal;
		DISPATCH();
	}

	op_mul_i64: {
		_RD_Inst* inst = code[ip]; ip++;
		regs[(int)inst->a]->kind = VK_INT;
		regs[(int)inst->a]->intVal = regs[(int)inst->b]->intVal * regs[(int)inst->c]->intVal;
		DISPATCH();
	}

	op_div_i64: {
		_RD_Inst* inst = code[ip]; ip++;
		double rhs = regs[(int)inst->c]->intVal;
		double result = 0.0;
		if (rhs != 0.0) {
			result = (double)((int64_t)(regs[(int)inst->b]->intVal / rhs));
		}
		regs[(int)inst->a]->kind = VK_INT;
		regs[(int)inst->a]->intVal = result;
		DISPATCH();
	}

	op_mod_i64: {
		_RD_Inst* inst = code[ip]; ip++;
		double lhs = regs[(int)inst->b]->intVal;
		double rhs = regs[(int)inst->c]->intVal;
		double result = 0.0;
		if (rhs != 0.0) {
			int64_t quot = (int64_t)(lhs / rhs);
			result = lhs - (double)quot * rhs;
		}
		regs[(int)inst->a]->kind = VK_INT;
		regs[(int)inst->a]->intVal = result;
		DISPATCH();
	}

	op_neg_i64: {
		_RD_Inst* inst = code[ip]; ip++;
		regs[(int)inst->a]->kind = VK_INT;
		regs[(int)inst->a]->intVal = -regs[(int)inst->b]->intVal;
		DISPATCH();
	}

	// === i64 Compare-Branch ===
	// Semantics: if condition true, skip C instructions (ip already incremented)

	op_beq_i64: {
		_RD_Inst* inst = code[ip]; ip++;
		if (regs[(int)inst->a]->intVal == regs[(int)inst->b]->intVal) {
			ip += (int)inst->c;
		}
		DISPATCH();
	}

	op_bne_i64: {
		_RD_Inst* inst = code[ip]; ip++;
		if (regs[(int)inst->a]->intVal != regs[(int)inst->b]->intVal) {
			ip += (int)inst->c;
		}
		DISPATCH();
	}

	op_blt_i64: {
		_RD_Inst* inst = code[ip]; ip++;
		if (regs[(int)inst->a]->intVal < regs[(int)inst->b]->intVal) {
			ip += (int)inst->c;
		}
		DISPATCH();
	}

	op_ble_i64: {
		_RD_Inst* inst = code[ip]; ip++;
		if (regs[(int)inst->a]->intVal <= regs[(int)inst->b]->intVal) {
			ip += (int)inst->c;
		}
		DISPATCH();
	}

	op_bgt_i64: {
		_RD_Inst* inst = code[ip]; ip++;
		if (regs[(int)inst->a]->intVal > regs[(int)inst->b]->intVal) {
			ip += (int)inst->c;
		}
		DISPATCH();
	}

	op_bge_i64: {
		_RD_Inst* inst = code[ip]; ip++;
		if (regs[(int)inst->a]->intVal >= regs[(int)inst->b]->intVal) {
			ip += (int)inst->c;
		}
		DISPATCH();
	}

	// === Control ===

	op_jump: {
		_RD_Inst* inst = code[ip]; ip++;
		// Decode signed 24-bit: a*65536 + b*256 + c, subtract 2^24 if >= 2^23
		int raw = (int)(inst->a * 65536.0 + inst->b * 256.0 + inst->c);
		if (raw >= 8388608) raw -= 16777216;
		ip += raw;
		DISPATCH();
	}

	op_call: {
		// Not yet implemented — fallback to MetaScript
		vm->ip = (double)ip;
		return 1.0;
	}

	op_ret: {
		_RD_Inst* inst = code[ip];
		vm->exitValue = regs[(int)inst->a];
		vm->halted = true;
		vm->ip = (double)(ip + 1);
		return 0.0;
	}

	op_halt: {
		_RD_Inst* inst = code[ip];
		vm->exitValue = regs[(int)inst->a];
		vm->halted = true;
		vm->ip = (double)(ip + 1);
		return 0.0;
	}

	op_print: {
		// Return to MetaScript — needs string handling
		vm->ip = (double)ip;
		return 1.0;
	}

done:
	vm->halted = true;
	vm->ip = (double)ip;
	return 0.0;

	#undef DISPATCH
}
