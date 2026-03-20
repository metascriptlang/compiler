/**
 * MetaScript JSON Runtime (C Backend)
 *
 * JSON parser + accessors. JsonValue is a class (ref-counted via msAllocTyped).
 * Struct layout matches MetaScript's flat-field class definition:
 *   kind, boolVal, numVal, strVal, arrVal, objKeys, objVals
 */

#ifndef MS_CORE_JSON_H
#define MS_CORE_JSON_H

#include "std/core/system/native.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ===== Types ===== */

/* JsonKind enum is defined by MetaScript codegen.
   Use numeric constants here for the C parser. */
#define MS_JSON_NULL    0
#define MS_JSON_BOOL    1
#define MS_JSON_NUMBER  2
#define MS_JSON_STRING  3
#define MS_JSON_ARRAY   4
#define MS_JSON_OBJECT  5

/* JsonValue struct — matches MetaScript's class JsonValue flat fields.
   The codegen emits struct JsonValue { ... } from the class definition.
   We suppress codegen emission with _DEFINED guard and define it here
   to ensure C parser can reference fields before MetaScript codegen runs. */
#ifndef JsonValue_DEFINED
#define JsonValue_DEFINED
typedef struct JsonValue JsonValue;
struct JsonValue {
    int32_t kind;  /* JsonKind — int32_t in C, codegen emits JsonKind typedef */
    MS_BOOL boolVal;
    double numVal;
    msString strVal;
    msRefArray arrVal;    /* JsonValue*[] — ref array of pointers */
    msStringArray objKeys;
    msRefArray objVals;   /* JsonValue*[] — ref array of pointers */
};
#endif

/* Forward: type info for GC */
extern msTypeInfo JsonValue_typeInfo;

/* ===== Allocation ===== */

static JsonValue* msJsonAlloc(int32_t kind) {
    JsonValue* v = (JsonValue*)msAllocTyped(sizeof(JsonValue), &JsonValue_typeInfo);
    memset(v, 0, sizeof(JsonValue));
    v->kind = kind;
    return v;
}

/* ===== Parsing Internals ===== */

static const char* msJsonSkipWs(const char* p, const char* end) {
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
    return p;
}

static const char* msJsonParseStr(const char* p, const char* end, msString* out) {
    const char* start = p;
    int has_escape = 0;
    const char* scan = p;
    while (scan < end && *scan != '"') {
        if (*scan == '\\') { has_escape = 1; scan += 2; }
        else scan++;
    }
    if (!has_escape) {
        *out = msStringNew(start, (int64_t)(scan - start));
        return scan < end ? scan + 1 : scan;
    }
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
    return p < end ? p + 1 : p;
}

static const char* msJsonParseValue(const char* p, const char* end, JsonValue** out);

static const char* msJsonParseNum(const char* p, const char* end, JsonValue** out) {
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
    JsonValue* v = msJsonAlloc(MS_JSON_NUMBER);
    v->numVal = strtod(start, NULL);
    *out = v;
    return p;
}

/* Helper: push a JsonValue* into a msRefArray */
static void msJsonPushRef(msRefArray* arr, JsonValue* val) {
    msGenericArrayPush(arr, val);
}

/* Helper: push a string into a msStringArray */
static void msJsonPushStr(msStringArray* arr, msString val) {
    msGenericArrayPush(arr, val);
}

static const char* msJsonParseValue(const char* p, const char* end, JsonValue** out) {
    p = msJsonSkipWs(p, end);
    if (p >= end) { *out = msJsonAlloc(MS_JSON_NULL); return p; }

    switch (*p) {
    case '"': {
        JsonValue* v = msJsonAlloc(MS_JSON_STRING);
        p = msJsonParseStr(p + 1, end, &v->strVal);
        *out = v;
        return p;
    }
    case '{': {
        JsonValue* v = msJsonAlloc(MS_JSON_OBJECT);
        p = msJsonSkipWs(p + 1, end);
        if (p < end && *p == '}') { *out = v; return p + 1; }
        while (p < end) {
            p = msJsonSkipWs(p, end);
            if (p >= end || *p != '"') break;
            msString key = MS_EMPTY_STRING;
            p = msJsonParseStr(p + 1, end, &key);
            p = msJsonSkipWs(p, end);
            if (p < end && *p == ':') p++;
            JsonValue* val = NULL;
            p = msJsonParseValue(p, end, &val);
            msJsonPushStr(&v->objKeys, key);
            msJsonPushRef(&v->objVals, val);
            p = msJsonSkipWs(p, end);
            if (p < end && *p == ',') p++;
            else break;
        }
        if (p < end && *p == '}') p++;
        *out = v;
        return p;
    }
    case '[': {
        JsonValue* v = msJsonAlloc(MS_JSON_ARRAY);
        p = msJsonSkipWs(p + 1, end);
        if (p < end && *p == ']') { *out = v; return p + 1; }
        while (p < end) {
            JsonValue* elem = NULL;
            p = msJsonParseValue(p, end, &elem);
            msJsonPushRef(&v->arrVal, elem);
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
            JsonValue* v = msJsonAlloc(MS_JSON_BOOL);
            v->boolVal = MS_TRUE;
            *out = v;
            return p + 4;
        }
        break;
    case 'f':
        if (p + 4 < end && p[1] == 'a' && p[2] == 'l' && p[3] == 's' && p[4] == 'e') {
            JsonValue* v = msJsonAlloc(MS_JSON_BOOL);
            v->boolVal = MS_FALSE;
            *out = v;
            return p + 5;
        }
        break;
    case 'n':
        if (p + 3 < end && p[1] == 'u' && p[2] == 'l' && p[3] == 'l') {
            *out = msJsonAlloc(MS_JSON_NULL);
            return p + 4;
        }
        break;
    default:
        if (*p == '-' || (*p >= '0' && *p <= '9')) {
            return msJsonParseNum(p, end, out);
        }
        break;
    }
    *out = msJsonAlloc(MS_JSON_NULL);
    return p;
}

/* ===== Public API ===== */

static inline JsonValue* msJsonParse(msString text) {
    JsonValue* result = NULL;
    const char* data = msCStr(text);
    msJsonParseValue(data, data + text.len, &result);
    return result ? result : msJsonAlloc(MS_JSON_NULL);
}

static inline JsonValue* msJsonGet(JsonValue* obj, msString key) {
    if (!obj || obj->kind != MS_JSON_OBJECT) return msJsonAlloc(MS_JSON_NULL);
    for (int64_t i = 0; i < obj->objKeys.len; i++) {
        if (msStringEquals(msArrayAccess(obj->objKeys, i), key)) {
            return (JsonValue*)msRefArrayAccess(obj->objVals, i);
        }
    }
    return msJsonAlloc(MS_JSON_NULL);
}

static inline JsonValue* msJsonAt(JsonValue* arr, double idx) {
    if (!arr || arr->kind != MS_JSON_ARRAY) return msJsonAlloc(MS_JSON_NULL);
    int64_t i = (int64_t)idx;
    if (i < 0 || i >= arr->arrVal.len) return msJsonAlloc(MS_JSON_NULL);
    return (JsonValue*)msRefArrayAccess(arr->arrVal, i);
}

static inline double msJsonLen(JsonValue* v) {
    if (!v) return 0.0;
    if (v->kind == MS_JSON_ARRAY) return (double)v->arrVal.len;
    if (v->kind == MS_JSON_OBJECT) return (double)v->objKeys.len;
    return 0.0;
}

static inline msString msJsonStr(JsonValue* v) {
    if (!v || v->kind != MS_JSON_STRING) return MS_EMPTY_STRING;
    return v->strVal;
}

static inline double msJsonNum(JsonValue* v) {
    if (!v || v->kind != MS_JSON_NUMBER) return 0.0;
    return v->numVal;
}

static inline MS_BOOL msJsonBool(JsonValue* v) {
    if (!v || v->kind != MS_JSON_BOOL) return MS_FALSE;
    return v->boolVal;
}

/* Free a JSON tree (recursive) */
static void msJsonFree(JsonValue* v) {
    if (!v) return;
    if (v->kind == MS_JSON_STRING) {
        msStringDestroy(v->strVal);
    } else if (v->kind == MS_JSON_ARRAY) {
        for (int64_t i = 0; i < v->arrVal.len; i++) {
            msJsonFree((JsonValue*)msRefArrayAccess(v->arrVal, i));
        }
        msArrayDestroy(v->arrVal);
    } else if (v->kind == MS_JSON_OBJECT) {
        for (int64_t i = 0; i < v->objKeys.len; i++) {
            msStringDestroy(msArrayAccess(v->objKeys, i));
        }
        msArrayDestroy(v->objKeys);
        for (int64_t i = 0; i < v->objVals.len; i++) {
            msJsonFree((JsonValue*)msRefArrayAccess(v->objVals, i));
        }
        msArrayDestroy(v->objVals);
    }
}

#ifdef __cplusplus
}
#endif

#endif /* MS_CORE_JSON_H */
