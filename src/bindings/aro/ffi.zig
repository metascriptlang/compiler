const std = @import("std");
const aro = @import("aro");
const Compilation = aro.Compilation;
const Preprocessor = aro.Preprocessor;
const Parser = aro.Parser;
const Tree = aro.Tree;
const Source = aro.Source;
const QualType = aro.QualType;
const Type = aro.Type;
const StringInterner = aro.StringInterner;

const Allocator = std.mem.Allocator;

// ── C-visible result structures ──────────────────────────────────────

const AroParam = struct {
    name: [*:0]const u8,
    type_str: [*:0]const u8,
};

const AroFunc = struct {
    name: [*:0]const u8,
    return_type: [*:0]const u8,
    params: [*]AroParam,
    n_params: c_int,
    is_variadic: bool,
};

const AroField = struct {
    name: [*:0]const u8,
    type_str: [*:0]const u8,
};

const AroStruct = struct {
    name: [*:0]const u8,
    fields: [*]AroField,
    n_fields: c_int,
    is_union: bool,
};

const AroEnumMember = struct {
    name: [*:0]const u8,
};

const AroEnum = struct {
    name: [*:0]const u8,
    members: [*]AroEnumMember,
    n_members: c_int,
};

const AroTypedef = struct {
    name: [*:0]const u8,
    target: [*:0]const u8,
};

pub const AroResult = struct {
    functions: [*]AroFunc,
    n_functions: c_int,
    structs: [*]AroStruct,
    n_structs: c_int,
    enums: [*]AroEnum,
    n_enums: c_int,
    typedefs: [*]AroTypedef,
    n_typedefs: c_int,
    error_msg: ?[*:0]const u8,

    arena: *std.heap.ArenaAllocator,
};

// ── Type-to-string helper ────────────────────────────────────────────

fn qualTypeToStr(qt: QualType, comp: *const Compilation, arena: Allocator) ![*:0]const u8 {
    const resolved = qt.base(comp);
    const ty = resolved.type;
    const base_qt = resolved.qt;

    var buf = std.ArrayList(u8).init(arena);

    if (base_qt.@"const") try buf.appendSlice("const ");
    if (base_qt.@"volatile") try buf.appendSlice("volatile ");

    switch (ty) {
        .void => try buf.appendSlice("void"),
        .bool => try buf.appendSlice("_Bool"),
        .nullptr_t => try buf.appendSlice("nullptr_t"),
        .int => |int_kind| {
            const name: []const u8 = switch (int_kind) {
                .char => "char",
                .schar => "signed char",
                .uchar => "unsigned char",
                .short => "short",
                .ushort => "unsigned short",
                .int => "int",
                .uint => "unsigned int",
                .long => "long",
                .ulong => "unsigned long",
                .long_long => "long long",
                .ulong_long => "unsigned long long",
                .int128 => "__int128",
                .uint128 => "unsigned __int128",
            };
            try buf.appendSlice(name);
        },
        .float => |float_kind| {
            const name: []const u8 = switch (float_kind) {
                .fp16 => "__fp16",
                .float16 => "_Float16",
                .float => "float",
                .double => "double",
                .long_double => "long double",
                .float128 => "__float128",
            };
            try buf.appendSlice(name);
        },
        .pointer => |ptr| {
            const child_str = try qualTypeToStr(ptr.child, comp, arena);
            try buf.appendSlice(std.mem.sliceTo(child_str, 0));
            try buf.append('*');
        },
        .array => |arr| {
            const elem_str = try qualTypeToStr(arr.elem, comp, arena);
            try buf.appendSlice(std.mem.sliceTo(elem_str, 0));
            try buf.appendSlice("[]");
        },
        .func => |func| {
            const ret_str = try qualTypeToStr(func.return_type, comp, arena);
            try buf.appendSlice(std.mem.sliceTo(ret_str, 0));
            try buf.appendSlice(" (*)(");
            for (func.params, 0..) |param, i| {
                if (i > 0) try buf.appendSlice(", ");
                const p_str = try qualTypeToStr(param.qt, comp, arena);
                try buf.appendSlice(std.mem.sliceTo(p_str, 0));
            }
            if (func.kind == .variadic) {
                if (func.params.len > 0) try buf.appendSlice(", ");
                try buf.appendSlice("...");
            }
            try buf.append(')');
        },
        .@"struct" => |record| {
            try buf.appendSlice("struct ");
            const name = record.name.lookup(comp);
            if (name.len > 0 and name[0] != '(') {
                try buf.appendSlice(name);
            } else {
                try buf.appendSlice("(anonymous)");
            }
        },
        .@"union" => |record| {
            try buf.appendSlice("union ");
            const name = record.name.lookup(comp);
            if (name.len > 0 and name[0] != '(') {
                try buf.appendSlice(name);
            } else {
                try buf.appendSlice("(anonymous)");
            }
        },
        .@"enum" => |enum_ty| {
            try buf.appendSlice("enum ");
            const name = enum_ty.name.lookup(comp);
            if (name.len > 0 and name[0] != '(') {
                try buf.appendSlice(name);
            } else {
                try buf.appendSlice("(anonymous)");
            }
        },
        .complex => |child| {
            try buf.appendSlice("_Complex ");
            const child_str = try qualTypeToStr(child, comp, arena);
            try buf.appendSlice(std.mem.sliceTo(child_str, 0));
        },
        .atomic => |child| {
            try buf.appendSlice("_Atomic(");
            const child_str = try qualTypeToStr(child, comp, arena);
            try buf.appendSlice(std.mem.sliceTo(child_str, 0));
            try buf.append(')');
        },
        .bit_int => |bi| {
            if (bi.signedness == .unsigned) try buf.appendSlice("unsigned ");
            try buf.appendSlice("_BitInt(");
            var num_buf: [20]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{bi.bits}) catch "?";
            try buf.appendSlice(num_str);
            try buf.append(')');
        },
        .vector => |vec| {
            const elem_str = try qualTypeToStr(vec.elem, comp, arena);
            try buf.appendSlice("__attribute__((vector_size(");
            try buf.appendSlice(std.mem.sliceTo(elem_str, 0));
            try buf.appendSlice(")))");
        },
        .typeof => |typeof| {
            return qualTypeToStr(typeof.base, comp, arena);
        },
        .typedef => |typedef| {
            return qualTypeToStr(typedef.base, comp, arena);
        },
        .attributed => |attr| {
            return qualTypeToStr(attr.base, comp, arena);
        },
    }

    try buf.append(0);
    const slice = buf.items;
    return @ptrCast(slice[0 .. slice.len - 1 :0]);
}

fn dupeStr(arena: Allocator, s: []const u8) ![*:0]const u8 {
    const d = try arena.alloc(u8, s.len + 1);
    @memcpy(d[0..s.len], s);
    d[s.len] = 0;
    return @ptrCast(d[0..s.len :0]);
}

// ── Core parse implementation ────────────────────────────────────────

fn parseHeaderImpl(
    path: [*:0]const u8,
    include_dirs: ?[*]const [*:0]const u8,
    n_include_dirs: c_int,
) !*AroResult {
    const gpa = std.heap.page_allocator;

    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_ptr.allocator();

    const empty_funcs = try arena.alloc(AroFunc, 0);
    const empty_structs = try arena.alloc(AroStruct, 0);
    const empty_enums = try arena.alloc(AroEnum, 0);
    const empty_typedefs = try arena.alloc(AroTypedef, 0);

    const result = try arena.create(AroResult);
    result.* = .{
        .functions = empty_funcs.ptr,
        .n_functions = 0,
        .structs = empty_structs.ptr,
        .n_structs = 0,
        .enums = empty_enums.ptr,
        .n_enums = 0,
        .typedefs = empty_typedefs.ptr,
        .n_typedefs = 0,
        .error_msg = null,
        .arena = arena_ptr,
    };

    // Open CWD
    const cwd = std.fs.cwd();

    // Init compilation
    var comp = Compilation.init(gpa, cwd);
    defer comp.deinit();

    // Add include directories
    const n: usize = if (n_include_dirs > 0) @intCast(n_include_dirs) else 0;
    if (include_dirs) |dirs| {
        for (0..n) |i| {
            const dir_str = std.mem.sliceTo(dirs[i], 0);
            comp.include_dirs.append(comp.gpa, dir_str) catch {};
        }
    }

    // Add source
    const path_slice = std.mem.sliceTo(path, 0);
    const source = comp.addSourceFromPath(path_slice) catch |err| {
        result.error_msg = try dupeStr(arena, @errorName(err));
        return result;
    };

    // Generate builtin macros (required by preprocessor)
    const builtin = comp.generateBuiltinMacros(.include_system_defines, null) catch |err| {
        result.error_msg = try dupeStr(arena, @errorName(err));
        return result;
    };

    // Empty user macros source (command-line defines would go here)
    const user_macros = comp.addSourceFromBuffer("<command line>", "") catch |err| {
        result.error_msg = try dupeStr(arena, @errorName(err));
        return result;
    };

    // Preprocess
    var pp = Preprocessor.initDefault(&comp) catch |err| {
        result.error_msg = try dupeStr(arena, @errorName(err));
        return result;
    };
    defer pp.deinit();

    pp.preprocessSources(&.{ source, builtin, user_macros }) catch |err| {
        result.error_msg = try dupeStr(arena, @errorName(err));
        return result;
    };

    // Parse
    var tree = Parser.parse(&pp) catch |err| {
        result.error_msg = try dupeStr(arena, @errorName(err));
        return result;
    };
    defer tree.deinit();

    // Collect declarations
    var funcs = std.ArrayList(AroFunc).init(arena);
    var structs = std.ArrayList(AroStruct).init(arena);
    var enums = std.ArrayList(AroEnum).init(arena);
    var typedefs = std.ArrayList(AroTypedef).init(arena);

    for (tree.root_decls.items) |decl_idx| {
        const node = decl_idx.get(&tree);
        switch (node) {
            .fn_proto => |proto| {
                try collectFunc(&funcs, proto.name_tok, proto.qt, &tree, &comp, arena);
            },
            .fn_def => |def| {
                try collectFunc(&funcs, def.name_tok, def.qt, &tree, &comp, arena);
            },
            .typedef => |td| {
                if (td.implicit) continue;
                const name = tree.tokSlice(td.name_tok);
                const target_str = try qualTypeToStr(td.qt, &comp, arena);
                try typedefs.append(.{
                    .name = try dupeStr(arena, name),
                    .target = target_str,
                });
            },
            .struct_decl => |decl| {
                try collectRecord(&structs, decl, false, &tree, &comp, arena);
            },
            .union_decl => |decl| {
                try collectRecord(&structs, decl, true, &tree, &comp, arena);
            },
            .enum_decl => |decl| {
                try collectEnum(&enums, decl, &tree, &comp, arena);
            },
            else => {},
        }
    }

    result.functions = funcs.items.ptr;
    result.n_functions = @intCast(funcs.items.len);
    result.structs = structs.items.ptr;
    result.n_structs = @intCast(structs.items.len);
    result.enums = enums.items.ptr;
    result.n_enums = @intCast(enums.items.len);
    result.typedefs = typedefs.items.ptr;
    result.n_typedefs = @intCast(typedefs.items.len);

    return result;
}

fn collectFunc(
    funcs: *std.ArrayList(AroFunc),
    name_tok: Tree.TokenIndex,
    qt: QualType,
    tree: *const Tree,
    comp: *const Compilation,
    arena: Allocator,
) !void {
    const name = tree.tokSlice(name_tok);
    const resolved = qt.base(comp);
    const ty = resolved.type;

    switch (ty) {
        .func => |func| {
            const ret_str = try qualTypeToStr(func.return_type, comp, arena);

            var params = try arena.alloc(AroParam, func.params.len);
            for (func.params, 0..) |param, i| {
                const pname = param.name.lookup(comp);
                params[i] = .{
                    .name = try dupeStr(arena, if (pname.len > 0) pname else ""),
                    .type_str = try qualTypeToStr(param.qt, comp, arena),
                };
            }

            try funcs.append(.{
                .name = try dupeStr(arena, name),
                .return_type = ret_str,
                .params = params.ptr,
                .n_params = @intCast(params.len),
                .is_variadic = func.kind == .variadic,
            });
        },
        else => {},
    }
}

fn collectRecord(
    list: *std.ArrayList(AroStruct),
    decl: Tree.Node.ContainerDecl,
    is_union: bool,
    tree: *const Tree,
    comp: *const Compilation,
    arena: Allocator,
) !void {
    const name = tree.tokSlice(decl.name_or_kind_tok);
    // Skip anonymous containers at top level (they're usually inside typedefs)
    const resolved = decl.container_qt.base(comp);

    var fields_list = std.ArrayList(AroField).init(arena);

    switch (resolved.type) {
        .@"struct" => |record| {
            for (record.fields) |field| {
                const fname = field.name.lookup(comp);
                try fields_list.append(.{
                    .name = try dupeStr(arena, if (fname.len > 0) fname else "(anonymous)"),
                    .type_str = try qualTypeToStr(field.qt, comp, arena),
                });
            }
        },
        .@"union" => |record| {
            for (record.fields) |field| {
                const fname = field.name.lookup(comp);
                try fields_list.append(.{
                    .name = try dupeStr(arena, if (fname.len > 0) fname else "(anonymous)"),
                    .type_str = try qualTypeToStr(field.qt, comp, arena),
                });
            }
        },
        else => {},
    }

    try list.append(.{
        .name = try dupeStr(arena, name),
        .fields = fields_list.items.ptr,
        .n_fields = @intCast(fields_list.items.len),
        .is_union = is_union,
    });
}

fn collectEnum(
    list: *std.ArrayList(AroEnum),
    decl: Tree.Node.ContainerDecl,
    tree: *const Tree,
    comp: *const Compilation,
    arena: Allocator,
) !void {
    const name = tree.tokSlice(decl.name_or_kind_tok);
    const resolved = decl.container_qt.base(comp);

    var members_list = std.ArrayList(AroEnumMember).init(arena);

    switch (resolved.type) {
        .@"enum" => |enum_ty| {
            for (enum_ty.fields) |field| {
                const mname = field.name.lookup(comp);
                try members_list.append(.{
                    .name = try dupeStr(arena, mname),
                });
            }
        },
        else => {},
    }

    try list.append(.{
        .name = try dupeStr(arena, name),
        .members = members_list.items.ptr,
        .n_members = @intCast(members_list.items.len),
    });
}

// ── Exported C API ───────────────────────────────────────────────────

export fn aroParseHeader(
    path: [*:0]const u8,
    include_dirs: ?[*]const [*:0]const u8,
    n_include_dirs: c_int,
) ?*AroResult {
    return parseHeaderImpl(path, include_dirs, n_include_dirs) catch null;
}

export fn aroNumFunctions(r: *AroResult) c_int {
    return r.n_functions;
}
export fn aroFnName(r: *AroResult, i: c_int) [*:0]const u8 {
    return r.functions[@intCast(i)].name;
}
export fn aroFnReturnType(r: *AroResult, i: c_int) [*:0]const u8 {
    return r.functions[@intCast(i)].return_type;
}
export fn aroFnNumParams(r: *AroResult, i: c_int) c_int {
    return r.functions[@intCast(i)].n_params;
}
export fn aroFnParamName(r: *AroResult, fi: c_int, pi: c_int) [*:0]const u8 {
    return r.functions[@intCast(fi)].params[@intCast(pi)].name;
}
export fn aroFnParamType(r: *AroResult, fi: c_int, pi: c_int) [*:0]const u8 {
    return r.functions[@intCast(fi)].params[@intCast(pi)].type_str;
}
export fn aroFnIsVariadic(r: *AroResult, i: c_int) bool {
    return r.functions[@intCast(i)].is_variadic;
}

export fn aroNumStructs(r: *AroResult) c_int {
    return r.n_structs;
}
export fn aroStructName(r: *AroResult, i: c_int) [*:0]const u8 {
    return r.structs[@intCast(i)].name;
}
export fn aroStructIsUnion(r: *AroResult, i: c_int) bool {
    return r.structs[@intCast(i)].is_union;
}
export fn aroStructNumFields(r: *AroResult, i: c_int) c_int {
    return r.structs[@intCast(i)].n_fields;
}
export fn aroStructFieldName(r: *AroResult, si: c_int, fi: c_int) [*:0]const u8 {
    return r.structs[@intCast(si)].fields[@intCast(fi)].name;
}
export fn aroStructFieldType(r: *AroResult, si: c_int, fi: c_int) [*:0]const u8 {
    return r.structs[@intCast(si)].fields[@intCast(fi)].type_str;
}

export fn aroNumEnums(r: *AroResult) c_int {
    return r.n_enums;
}
export fn aroEnumName(r: *AroResult, i: c_int) [*:0]const u8 {
    return r.enums[@intCast(i)].name;
}
export fn aroEnumNumMembers(r: *AroResult, i: c_int) c_int {
    return r.enums[@intCast(i)].n_members;
}
export fn aroEnumMemberName(r: *AroResult, ei: c_int, mi: c_int) [*:0]const u8 {
    return r.enums[@intCast(ei)].members[@intCast(mi)].name;
}

export fn aroNumTypedefs(r: *AroResult) c_int {
    return r.n_typedefs;
}
export fn aroTypedefName(r: *AroResult, i: c_int) [*:0]const u8 {
    return r.typedefs[@intCast(i)].name;
}
export fn aroTypedefTarget(r: *AroResult, i: c_int) [*:0]const u8 {
    return r.typedefs[@intCast(i)].target;
}

export fn aroErrorMsg(r: *AroResult) ?[*:0]const u8 {
    return r.error_msg;
}

export fn aroResultFree(r: *AroResult) void {
    const arena_ptr = r.arena;
    arena_ptr.deinit();
    std.heap.page_allocator.destroy(arena_ptr);
}
