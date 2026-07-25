/**
 * MetaScript Test Runner
 *
 * Provides test execution and output formatting for `msc test`.
 * Codegen emits per-module MsTestEntry tables and a MsTestModule descriptor
 * array. This library runs all tests, formats output, and prints summary.
 *
 * Only included in test builds — zero overhead in production.
 */

#ifndef MS_TEST_H
#define MS_TEST_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>
#include <time.h>
#include <unistd.h>

/* Per-test failure flag — reset before each test, set by assert.
 * Defined in generated code (entry module), declared here. */
extern int __ms_test_failed;

/* ---- ANSI color support ---- */

static int __ms_color_enabled = -1;

static inline int ms_use_color(void) {
    if (__ms_color_enabled < 0) {
        const char* nc = getenv("NO_COLOR");
        if (nc && nc[0] != '\0') {
            __ms_color_enabled = 0;
        } else {
            __ms_color_enabled = isatty(fileno(stdout));
        }
    }
    return __ms_color_enabled;
}

#define MS_C_RESET   (ms_use_color() ? "\x1b[0m"    : "")
#define MS_C_GREEN   (ms_use_color() ? "\x1b[32m"   : "")
#define MS_C_RED     (ms_use_color() ? "\x1b[31m"   : "")
#define MS_C_CYAN    (ms_use_color() ? "\x1b[36m"   : "")
#define MS_C_DIM     (ms_use_color() ? "\x1b[2m"    : "")
#define MS_C_BOLD    (ms_use_color() ? "\x1b[1m"    : "")
#define MS_C_BOLDRED (ms_use_color() ? "\x1b[1;31m" : "")

/* ---- Test entry metadata (populated by codegen per module) ---- */

typedef struct {
    const char* name;
    const char* group;   /* NULL for ungrouped tests */
    void (*fn)(void);
} MsTestEntry;

/* ---- Module descriptor (built by dispatcher) ---- */

typedef struct {
    const char* file_path;
    MsTestEntry* entries;  /* NULL-terminated array */
} MsTestModule;

/* ---- Failure record ---- */

#define MS_MAX_FAILURES 1024
#define MS_PA_DIAG_SIZE 1024

typedef struct {
    const char* test_name;
    const char* file_path;
    char assert_msg[MS_PA_DIAG_SIZE];
    const char* assert_file;
    int assert_line;
    char pa_diagram[MS_PA_DIAG_SIZE];
} MsFailure;

static MsFailure __ms_failures[MS_MAX_FAILURES];
static int __ms_failure_count = 0;

/* Current test context */
static const char* __ms_current_test_name = NULL;
static const char* __ms_current_file_path = NULL;

/* Last assertion info — set by msTestCheckFail in module TU, read by dispatcher TU */
extern const char* __ms_last_assert_msg;
extern const char* __ms_last_assert_file;
extern int __ms_last_assert_line;

/* ---- Assert failure (called by codegen-emitted assert checks) ---- */

static inline void msTestCheckFail(const char* msg, const char* file, int line) {
    /* Own the message: callers may pass a heap string they free right after
     * this returns, while the dispatcher reads it once the test unwinds. */
    static char __ms_assert_msg_buf[MS_PA_DIAG_SIZE];
    __ms_test_failed = 1;
    if (msg != NULL) {
        strncpy(__ms_assert_msg_buf, msg, MS_PA_DIAG_SIZE - 1);
        __ms_assert_msg_buf[MS_PA_DIAG_SIZE - 1] = '\0';
        __ms_last_assert_msg = __ms_assert_msg_buf;
    } else {
        __ms_last_assert_msg = "";
    }
    __ms_last_assert_file = file;
    __ms_last_assert_line = line;
}

/* ---- Power Assert runtime ---- */

#define MS_PA_MAX_ENTRIES 32

typedef struct {
    int col;
    char label[64];
    char val[128];
} MsPaEntry;

static char __pa_source[256];
static MsPaEntry __pa_entries[MS_PA_MAX_ENTRIES];
static int __pa_count = 0;
/* Power assert buffer — written by __paEnd in module TU, read by dispatcher TU */
extern char __ms_pa_buffer[MS_PA_DIAG_SIZE];
extern int __ms_pa_pending;

static inline void __paBegin(const char* source) {
    strncpy(__pa_source, source, sizeof(__pa_source) - 1);
    __pa_source[sizeof(__pa_source) - 1] = '\0';
    __pa_count = 0;
}

static inline void __paValueStr(int col, const char* label, const char* val) {
    if (__pa_count >= MS_PA_MAX_ENTRIES) return;
    MsPaEntry* e = &__pa_entries[__pa_count++];
    e->col = col;
    strncpy(e->label, label, sizeof(e->label) - 1);
    e->label[sizeof(e->label) - 1] = '\0';
    snprintf(e->val, sizeof(e->val), "\"%s\"", val ? val : "(null)");
}

static inline void __paValueNum(int col, const char* label, double val) {
    if (__pa_count >= MS_PA_MAX_ENTRIES) return;
    MsPaEntry* e = &__pa_entries[__pa_count++];
    e->col = col;
    strncpy(e->label, label, sizeof(e->label) - 1);
    e->label[sizeof(e->label) - 1] = '\0';
    snprintf(e->val, sizeof(e->val), "%g", val);
}

static inline void __paValueInt(int col, const char* label, int64_t val) {
    if (__pa_count >= MS_PA_MAX_ENTRIES) return;
    MsPaEntry* e = &__pa_entries[__pa_count++];
    e->col = col;
    strncpy(e->label, label, sizeof(e->label) - 1);
    e->label[sizeof(e->label) - 1] = '\0';
    snprintf(e->val, sizeof(e->val), "%" PRId64, val);
}

static inline void __paValueBool(int col, const char* label, int val) {
    if (__pa_count >= MS_PA_MAX_ENTRIES) return;
    MsPaEntry* e = &__pa_entries[__pa_count++];
    e->col = col;
    strncpy(e->label, label, sizeof(e->label) - 1);
    e->label[sizeof(e->label) - 1] = '\0';
    snprintf(e->val, sizeof(e->val), "%s", val ? "true" : "false");
}

static inline void __pa_sort_entries(void) {
    for (int i = 1; i < __pa_count; i++) {
        MsPaEntry tmp = __pa_entries[i];
        int j = i - 1;
        while (j >= 0 && __pa_entries[j].col > tmp.col) {
            __pa_entries[j + 1] = __pa_entries[j];
            j--;
        }
        __pa_entries[j + 1] = tmp;
    }
}

static inline void __paEnd(void) {
    if (__pa_count == 0) return;
    __pa_sort_entries();

    char* buf = __ms_pa_buffer;
    int remaining = MS_PA_DIAG_SIZE;
    int written;
    const char* prefix = "assert ";
    int prefix_len = (int)strlen(prefix);

    written = snprintf(buf, remaining, "%s%s\n", prefix, __pa_source);
    buf += written; remaining -= written;

    for (int i = __pa_count - 1; i >= 0 && remaining > 1; i--) {
        int pos = 0;
        for (int j = 0; j <= i && remaining > 1; j++) {
            int target = prefix_len + __pa_entries[j].col;
            while (pos < target && remaining > 1) {
                *buf++ = ' '; remaining--; pos++;
            }
            if (j == i) {
                int vlen = (int)strlen(__pa_entries[j].val);
                if (vlen > remaining - 1) vlen = remaining - 1;
                memcpy(buf, __pa_entries[j].val, vlen);
                buf += vlen; remaining -= vlen; pos += vlen;
            } else {
                if (remaining > 1) { *buf++ = '|'; remaining--; pos++; }
            }
        }
        if (remaining > 1) { *buf++ = '\n'; remaining--; }
    }
    *buf = '\0';
    __ms_pa_pending = 1;
    __pa_count = 0;
}

/* ---- Timing helper ---- */

static inline long ms_clock_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

/* ---- Record a failure ---- */

static inline void ms_record_failure(void) {
    if (__ms_failure_count >= MS_MAX_FAILURES) return;
    MsFailure* f = &__ms_failures[__ms_failure_count++];
    f->test_name = __ms_current_test_name;
    f->file_path = __ms_current_file_path;
    strncpy(f->assert_msg, __ms_last_assert_msg != NULL ? __ms_last_assert_msg : "", MS_PA_DIAG_SIZE - 1);
    f->assert_msg[MS_PA_DIAG_SIZE - 1] = '\0';
    f->assert_file = __ms_last_assert_file;
    f->assert_line = __ms_last_assert_line;
    if (__ms_pa_pending) {
        memcpy(f->pa_diagram, __ms_pa_buffer, MS_PA_DIAG_SIZE);
        __ms_pa_pending = 0;
    } else {
        f->pa_diagram[0] = '\0';
    }
}

/* ---- Main test runner ---- */
/* Takes a NULL-terminated array of MsTestModule descriptors.
 * Runs all tests, prints per-file lines, failure details, and summary. */

static inline int ms_test_main(MsTestModule* modules, int argc, char** argv) {
    const char* filter = (argc > 1) ? argv[1] : NULL;
    long t0_all = ms_clock_ms();

    int total_passed = 0, total_failed = 0;
    int files_passed = 0, files_failed = 0, files_total = 0;

    for (int m = 0; modules[m].entries != NULL; m++) {
        MsTestModule* mod = &modules[m];
        MsTestEntry* entries = mod->entries;
        int mod_passed = 0, mod_failed = 0;
        long t0_mod = ms_clock_ms();

        __ms_current_file_path = mod->file_path;

        for (int i = 0; entries[i].fn != NULL; i++) {
            MsTestEntry* e = &entries[i];

            if (filter != NULL && strstr(e->name, filter) == NULL)
                continue;

            __ms_test_failed = 0;
            __ms_last_assert_msg = NULL;
            __ms_last_assert_file = NULL;
            __ms_last_assert_line = 0;
            __ms_pa_pending = 0;
            __ms_current_test_name = e->name;
            e->fn();

            if (msErr) {
                if (__ms_last_assert_msg == NULL)
                    __ms_last_assert_msg = "uncaught exception escaped the test body";
                __ms_test_failed = 1;
                msDiscardCurrentException();
            }

            if (__ms_test_failed) {
                mod_failed++;
                ms_record_failure();
            } else {
                mod_passed++;
            }
        }

        /* Skip modules with no tests (or all filtered out) */
        if (mod_passed + mod_failed == 0) continue;

        long elapsed = ms_clock_ms() - t0_mod;
        int count = mod_passed + mod_failed;
        files_total++;

        /* Per-file line */
        if (mod_failed > 0) {
            files_failed++;
            printf("%s\xc3\x97%s %s%s%s (%d) %s%ldms%s\n",
                MS_C_RED, MS_C_RESET,
                MS_C_RED, mod->file_path, MS_C_RESET,
                count, MS_C_CYAN, elapsed, MS_C_RESET);
        } else {
            files_passed++;
            printf("%s\xe2\x9c\x93%s %s%s%s (%d) %s%ldms%s\n",
                MS_C_GREEN, MS_C_RESET,
                MS_C_GREEN, mod->file_path, MS_C_RESET,
                count, MS_C_CYAN, elapsed, MS_C_RESET);
        }

        total_passed += mod_passed;
        total_failed += mod_failed;
    }

    /* Failure detail blocks */
    if (__ms_failure_count > 0) {
        const char* last_file = NULL;
        for (int i = 0; i < __ms_failure_count; i++) {
            MsFailure* f = &__ms_failures[i];

            if (last_file == NULL || strcmp(last_file, f->file_path) != 0) {
                if (last_file != NULL) printf("\n");
                printf("\n %s%sFAIL%s  %s\n\n",
                    MS_C_BOLDRED, MS_C_BOLD, MS_C_RESET, f->file_path);
                last_file = f->file_path;
            }

            printf("  %s\xc3\x97 %s%s\n",
                MS_C_RED, f->test_name, MS_C_RESET);

            if (f->pa_diagram[0] != '\0') {
                printf("    AssertionError:\n");
                const char* p = f->pa_diagram;
                while (*p) {
                    printf("    ");
                    while (*p && *p != '\n') { putchar(*p); p++; }
                    putchar('\n');
                    if (*p == '\n') p++;
                }
            } else if (f->assert_msg[0] != '\0') {
                printf("    AssertionError: %s\n", f->assert_msg);
            }

            if (f->assert_file) {
                printf("\n      %sat %s:%d%s\n",
                    MS_C_DIM, f->assert_file, f->assert_line, MS_C_RESET);
            }
            printf("\n");
        }
    }

    /* Summary */
    long total_duration = ms_clock_ms() - t0_all;
    int total_tests = total_passed + total_failed;

    printf("\n");
    printf(" Test Files  %s%d passed%s", MS_C_GREEN, files_passed, MS_C_RESET);
    if (files_failed > 0) printf(" | %s%d failed%s", MS_C_RED, files_failed, MS_C_RESET);
    printf(" (%d)\n", files_total);

    printf("      Tests  %s%d passed%s", MS_C_GREEN, total_passed, MS_C_RESET);
    if (total_failed > 0) printf(" | %s%d failed%s", MS_C_RED, total_failed, MS_C_RESET);
    printf(" (%d)\n", total_tests);

    printf("   Duration  %s%ldms%s\n", MS_C_CYAN, total_duration, MS_C_RESET);
    printf("\n");

    return total_failed > 0 ? 1 : 0;
}

#endif /* MS_TEST_H */
