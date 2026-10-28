#include "companion.h"
#include <array>
#include <span>
#include <stdexcept>

extern "C" int companionValue(void) {
    std::array<int, 3> values{10, 14, 18};
    std::span<const int> view(values);
    try {
        throw std::runtime_error("companion");
    } catch (const std::runtime_error&) {
        return view[0] + view[1] + view[2];
    }
}
