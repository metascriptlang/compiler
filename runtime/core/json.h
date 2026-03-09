/**
 * MetaScript JSON Runtime (C Backend)
 *
 * Minimal JSON parser + builder. Values are ref-counted via msAllocTyped.
 * API designed for MetaScript's class system (JsonValue is a ref type).
 */

#ifndef MS_CORE_JSON_H
#define MS_CORE_JSON_H

#include "system.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ===== Types ===== */

typedef int32_t MsJsonKind;
#define MsJsonKind_Null    0
#define MsJsonKind_Bool    1
#define MsJsonKind_Number  2
#define MsJsonKind_String  3
#define MsJsonKind_Array   4
#define MsJsonKind_Object  5

typedef struct MsJsonValue MsJsonValue;
typedef struct MsJsonEntry MsJsonEntry;

struct MsJsonEntry {
    msString key;
    MsJsonValue* val;
};

struct MsJsonValue {
    MsJsonKind kind;
    union {
        MS_BOOL boolVal;
        double numVal;
        msString strVal;
        struct {
            MsJsonValue** items;
            int64_t len;
            int64_t cap;
        } arr;
        struct {
            MsJsonEntry* entries;
            int64_t len;
            int64_t cap;
        } obj;
    };
};

/* Forward: type info for GC */
extern msTypeInfo MsJsonValue_typeInfo;

/* ===== Parsing ===== */

static MsJsonValue* msJsonAlloc(MsJsonKind kind) {
    MsJsonValue* v = (MsJsonValue*)msAllocTyped(sizeof(MsJsonValue), &MsJsonValue_typeInfo);
    memset(v, 0, sizeof(MsJsonValue));
    v->kind = kind;
    return v;
}

/* Skip whitespace */
static const char* msJsonSkipWs(const char* p, const char* end) {
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
    return p;
}

/* Parse a JSON string (starting after opening ") */
static const char* msJsonParseStr(const char* p, const char* end, msString* out) {
    /* p points after opening quote */
    const char* start = p;
    /* Quick scan for unescaped string */
    int has_escape = 0;
    const char* scan = p;
    while (scan < end && *scan != '"') {
        if (*scan == '\\') { has_escape = 1; scan += 2; }
        else scan++;
    }
    if (!has_escape) {
        *out = msStringNew(start, (int64_t)(scan - start));
        return scan < end ? scan + 1 : scan; /* skip closing " */
    }
    /* Slow path: unescape */
    int64_t maxLen = (int64_t)(scan - start);
    char* buf = (char*)malloc(maxLen + 1);
    int64_t len = 0;
    p = start;
    while (p < end && *p != '"') {
        if (*p == '\\' && p + 1 < end) {
            p++;
            switch (*p) {
                case '"': buf[len++] = '"'; break;
                case '\\': buf[len++] = '\\'; break;
                case '/': buf[len++] = '/'; break;
                case 'n': buf[len++] = '\n'; break;
                case 'r': buf[len++] = '\r'; break;
                case 't': buf[len++] = '\t'; break;
                case 'b': buf[len++] = '\b'; break;
                case 'f': buf[len++] = '\f'; break;
                default: buf[len++] = *p; break;
            }
            p++;
        } else {
            buf[len++] = *p++;
        }
    }
    buf[len] = '\0';
    *out = msStringNew(buf, len);
    free(buf);
    return p < end ? p + 1 : p; /* skip closing " */
}

/* Forward declaration */
static const char* msJsonParseValue(const char* p, const char* end, MsJsonValue** out);

/* Parse a JSON number */
static const char* msJsonParseNum(const char* p, const char* end, MsJsonValue** out) {
    const char* start = p;
    if (p < end && *p == '-') p++;
    while (p < end && *p >= '0' && *p <= '9') p++;
    if (p < end && *p == '.') {
        p++;
        while (p < end && *p >= '0' && *p <= '9') p++;
    }
    if (p < end && (*p == 'e' || *p == 'E')) {
        p++;
        if (p < end && (*p == '+' || *p == '-')) p++;
        while (p < end && *p >= '0' && *p <= '9') p++;
    }
    MsJsonValue* v = msJsonAlloc(MsJsonKind_Number);
    v->numVal = strtod(start, NULL);
    *out = v;
    return p;
}

/* Parse a JSON value */
static const char* msJsonParseValue(const char* p, const char* end, MsJsonValue** out) {
    p = msJsonSkipWs(p, end);
    if (p >= end) { *out = msJsonAlloc(MsJsonKind_Null); return p; }

    switch (*p) {
    case '"': {
        MsJsonValue* v = msJsonAlloc(MsJsonKind_String);
        p = msJsonParseStr(p + 1, end, &v->strVal);
        *out = v;
        return p;
    }
    case '{': {
        MsJsonValue* v = msJsonAlloc(MsJsonKind_Object);
        p = msJsonSkipWs(p + 1, end);
        if (p < end && *p == '}') { *out = v; return p + 1; }
        while (p < end) {
            p = msJsonSkipWs(p, end);
            if (p >= end || *p != '"') break;
            msString key = MS_EMPTY_STRING;
            p = msJsonParseStr(p + 1, end, &key);
            p = msJsonSkipWs(p, end);
            if (p < end && *p == ':') p++;
            MsJsonValue* val = NULL;
            p = msJsonParseValue(p, end, &val);
            /* Grow entries */
            if (v->obj.len >= v->obj.cap) {
                int64_t newCap = v->obj.cap < 4 ? 4 : v->obj.cap * 2;
                v->obj.entries = (MsJsonEntry*)realloc(v->obj.entries, newCap * sizeof(MsJsonEntry));
                v->obj.cap = newCap;
            }
            v->obj.entries[v->obj.len].key = key;
            v->obj.entries[v->obj.len].val = val;
            v->obj.len++;
            p = msJsonSkipWs(p, end);
            if (p < end && *p == ',') p++;
            else break;
        }
        if (p < end && *p == '}') p++;
        *out = v;
        return p;
    }
    case '[': {
        MsJsonValue* v = msJsonAlloc(MsJsonKind_Array);
        p = msJsonSkipWs(p + 1, end);
        if (p < end && *p == ']') { *out = v; return p + 1; }
        while (p < end) {
            MsJsonValue* elem = NULL;
            p = msJsonParseValue(p, end, &elem);
            /* Grow items */
            if (v->arr.len >= v->arr.cap) {
                int64_t newCap = v->arr.cap < 4 ? 4 : v->arr.cap * 2;
                v->arr.items = (MsJsonValue**)realloc(v->arr.items, newCap * sizeof(MsJsonValue*));
                v->arr.cap = newCap;
            }
            v->arr.items[v->arr.len++] = elem;
            p = msJsonSkipWs(p, end);
            if (p < end && *p == ',') p++;
            else break;
        }
        if (p < end && *p == ']') p++;
        *out = v;
        return p;
    }
    case 't':
        if (p + 3 < end && p[1] == 'r' && p[2] == 'u' && p[3] == 'e') {
            MsJsonValue* v = msJsonAlloc(MsJsonKind_Bool);
            v->boolVal = MS_TRUE;
            *out = v;
            return p + 4;
        }
        break;
    case 'f':
        if (p + 4 < end && p[1] == 'a' && p[2] == 'l' && p[3] == 's' && p[4] == 'e') {
            MsJsonValue* v = msJsonAlloc(MsJsonKind_Bool);
            v->boolVal = MS_FALSE;
            *out = v;
            return p + 5;
        }
        break;
    case 'n':
        if (p + 3 < end && p[1] == 'u' && p[2] == 'l' && p[3] == 'l') {
            *out = msJsonAlloc(MsJsonKind_Null);
            return p + 4;
        }
        break;
    default:
        if (*p == '-' || (*p >= '0' && *p <= '9')) {
            return msJsonParseNum(p, end, out);
        }
        break;
    }
    *out = msJsonAlloc(MsJsonKind_Null);
    return p;
}

/* ===== Public API ===== */

/* Parse JSON text → JsonValue* */
static inline MsJsonValue* msJsonParse(msString text) {
    MsJsonValue* result = NULL;
    const char* data = msCStr(text);
    msJsonParseValue(data, data + text.len, &result);
    return result ? result : msJsonAlloc(MsJsonKind_Null);
}

/* Get object field by key → JsonValue* (null if not found) */
static inline MsJsonValue* msJsonGet(MsJsonValue* obj, msString key) {
    if (!obj || obj->kind != MsJsonKind_Object) return msJsonAlloc(MsJsonKind_Null);
    for (int64_t i = 0; i < obj->obj.len; i++) {
        if (msStringEquals(obj->obj.entries[i].key, key)) {
            return obj->obj.entries[i].val;
        }
    }
    return msJsonAlloc(MsJsonKind_Null);
}

/* Get array element → JsonValue* */
static inline MsJsonValue* msJsonAt(MsJsonValue* arr, double idx) {
    if (!arr || arr->kind != MsJsonKind_Array) return msJsonAlloc(MsJsonKind_Null);
    int64_t i = (int64_t)idx;
    if (i < 0 || i >= arr->arr.len) return msJsonAlloc(MsJsonKind_Null);
    return arr->arr.items[i];
}

/* Accessors */
static inline msString msJsonAsString(MsJsonValue* v) {
    if (!v || v->kind != MsJsonKind_String) return MS_EMPTY_STRING;
    return v->strVal;
}

static inline double msJsonAsNumber(MsJsonValue* v) {
    if (!v || v->kind != MsJsonKind_Number) return 0;
    return v->numVal;
}

static inline MS_BOOL msJsonAsBool(MsJsonValue* v) {
    if (!v || v->kind != MsJsonKind_Bool) return MS_FALSE;
    return v->boolVal;
}

static inline double msJsonLen(MsJsonValue* v) {
    if (!v) return 0;
    if (v->kind == MsJsonKind_Array) return (double)v->arr.len;
    if (v->kind == MsJsonKind_Object) return (double)v->obj.len;
    if (v->kind == MsJsonKind_String) return (double)v->strVal.len;
    return 0;
}

/* ===== Builders ===== */

static inline MsJsonValue* msJsonNewNull(void) { return msJsonAlloc(MsJsonKind_Null); }

static inline MsJsonValue* msJsonNewBool(MS_BOOL b) {
    MsJsonValue* v = msJsonAlloc(MsJsonKind_Bool);
    v->boolVal = b;
    return v;
}

static inline MsJsonValue* msJsonNewNumber(double n) {
    MsJsonValue* v = msJsonAlloc(MsJsonKind_Number);
    v->numVal = n;
    return v;
}

static inline MsJsonValue* msJsonNewString(msString s) {
    MsJsonValue* v = msJsonAlloc(MsJsonKind_String);
    v->strVal = s;
    return v;
}

static inline MsJsonValue* msJsonNewObject(void) { return msJsonAlloc(MsJsonKind_Object); }
static inline MsJsonValue* msJsonNewArray(void) { return msJsonAlloc(MsJsonKind_Array); }

static inline void msJsonSet(MsJsonValue* obj, msString key, MsJsonValue* val) {
    if (!obj || obj->kind != MsJsonKind_Object) return;
    /* Check for existing key */
    for (int64_t i = 0; i < obj->obj.len; i++) {
        if (msStringEquals(obj->obj.entries[i].key, key)) {
            obj->obj.entries[i].val = val;
            return;
        }
    }
    /* Add new entry */
    if (obj->obj.len >= obj->obj.cap) {
        int64_t newCap = obj->obj.cap < 4 ? 4 : obj->obj.cap * 2;
        obj->obj.entries = (MsJsonEntry*)realloc(obj->obj.entries, newCap * sizeof(MsJsonEntry));
        obj->obj.cap = newCap;
    }
    obj->obj.entries[obj->obj.len].key = key;
    obj->obj.entries[obj->obj.len].val = val;
    obj->obj.len++;
}

static inline void msJsonPush(MsJsonValue* arr, MsJsonValue* val) {
    if (!arr || arr->kind != MsJsonKind_Array) return;
    if (arr->arr.len >= arr->arr.cap) {
        int64_t newCap = arr->arr.cap < 4 ? 4 : arr->arr.cap * 2;
        arr->arr.items = (MsJsonValue**)realloc(arr->arr.items, newCap * sizeof(MsJsonValue*));
        arr->arr.cap = newCap;
    }
    arr->arr.items[arr->arr.len++] = val;
}

/* ===== Stringify ===== */

/* Forward decl */
static void msJsonStringifyInto(MsJsonValue* v, char** buf, int64_t* len, int64_t* cap);

static void msJsonBufAppend(char** buf, int64_t* len, int64_t* cap, const char* s, int64_t slen) {
    while (*len + slen >= *cap) {
        *cap = *cap < 64 ? 64 : *cap * 2;
        *buf = (char*)realloc(*buf, *cap);
    }
    memcpy(*buf + *len, s, slen);
    *len += slen;
}

static void msJsonBufAppendChar(char** buf, int64_t* len, int64_t* cap, char c) {
    msJsonBufAppend(buf, len, cap, &c, 1);
}

static void msJsonEscapeString(char** buf, int64_t* len, int64_t* cap, msString s) {
    msJsonBufAppendChar(buf, len, cap, '"');
    const char* data = msCStr(s);
    for (int64_t i = 0; i < s.len; i++) {
        char c = data[i];
        switch (c) {
            case '"': msJsonBufAppend(buf, len, cap, "\\\"", 2); break;
            case '\\': msJsonBufAppend(buf, len, cap, "\\\\", 2); break;
            case '\n': msJsonBufAppend(buf, len, cap, "\\n", 2); break;
            case '\r': msJsonBufAppend(buf, len, cap, "\\r", 2); break;
            case '\t': msJsonBufAppend(buf, len, cap, "\\t", 2); break;
            default: msJsonBufAppendChar(buf, len, cap, c); break;
        }
    }
    msJsonBufAppendChar(buf, len, cap, '"');
}

static void msJsonStringifyInto(MsJsonValue* v, char** buf, int64_t* len, int64_t* cap) {
    if (!v) { msJsonBufAppend(buf, len, cap, "null", 4); return; }
    switch (v->kind) {
    case MsJsonKind_Null:
        msJsonBufAppend(buf, len, cap, "null", 4);
        break;
    case MsJsonKind_Bool:
        if (v->boolVal) msJsonBufAppend(buf, len, cap, "true", 4);
        else msJsonBufAppend(buf, len, cap, "false", 5);
        break;
    case MsJsonKind_Number: {
        char tmp[64];
        int n = snprintf(tmp, sizeof(tmp), "%.17g", v->numVal);
        msJsonBufAppend(buf, len, cap, tmp, n);
        break;
    }
    case MsJsonKind_String:
        msJsonEscapeString(buf, len, cap, v->strVal);
        break;
    case MsJsonKind_Array:
        msJsonBufAppendChar(buf, len, cap, '[');
        for (int64_t i = 0; i < v->arr.len; i++) {
            if (i > 0) msJsonBufAppendChar(buf, len, cap, ',');
            msJsonStringifyInto(v->arr.items[i], buf, len, cap);
        }
        msJsonBufAppendChar(buf, len, cap, ']');
        break;
    case MsJsonKind_Object:
        msJsonBufAppendChar(buf, len, cap, '{');
        for (int64_t i = 0; i < v->obj.len; i++) {
            if (i > 0) msJsonBufAppendChar(buf, len, cap, ',');
            msJsonEscapeString(buf, len, cap, v->obj.entries[i].key);
            msJsonBufAppendChar(buf, len, cap, ':');
            msJsonStringifyInto(v->obj.entries[i].val, buf, len, cap);
        }
        msJsonBufAppendChar(buf, len, cap, '}');
        break;
    }
}

static inline msString msJsonStringify(MsJsonValue* v) {
    char* buf = NULL;
    int64_t len = 0, cap = 0;
    msJsonStringifyInto(v, &buf, &len, &cap);
    if (!buf) return MS_EMPTY_STRING;
    msString result = msStringNew(buf, len);
    free(buf);
    return result;
}

/* ===== Cleanup ===== */

/* Recursively free a JSON value tree (entries/items arrays + child nodes). */
static void msJsonFree(MsJsonValue* v) {
    if (!v) return;
    switch (v->kind) {
    case MsJsonKind_Array:
        for (int64_t i = 0; i < v->arr.len; i++) {
            msJsonFree(v->arr.items[i]);
        }
        free(v->arr.items);
        break;
    case MsJsonKind_Object:
        for (int64_t i = 0; i < v->obj.len; i++) {
            msJsonFree(v->obj.entries[i].val);
        }
        free(v->obj.entries);
        break;
    default:
        break;
    }
    /* Note: MsJsonValue itself is allocated via msAllocTyped (RC). */
}

/* TypeInfo — no trace/destroy needed (msJsonFree handles tree cleanup) */
msTypeInfo MsJsonValue_typeInfo = { "MsJsonValue", MS_FALSE, NULL, NULL };

#ifdef __cplusplus
}
#endif

#endif /* MS_CORE_JSON_H */
