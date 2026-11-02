#include <cstdio>
#include <libunwind.h>
#include <unwind.h>

static _Unwind_Reason_Code countFrame(struct _Unwind_Context *, void *data) {
    ++*static_cast<int *>(data);
    return _URC_NO_REASON;
}

int main() {
    unw_context_t context;
    unw_cursor_t cursor;
    if (unw_getcontext(&context) != 0 || unw_init_local(&cursor, &context) != 0) return 1;
    int steps = 0;
    while (unw_step(&cursor) > 0) ++steps;
    int frames = 0;
    _Unwind_Backtrace(countFrame, &frames);
    std::printf("unwind steps=%d backtrace=%d\n", steps >= 1, frames >= 1);
    return 0;
}
