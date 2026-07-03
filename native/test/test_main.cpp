// Entry point for the native unit-test binary.
//
// doctest generates main() here; every other translation unit in the test target
// only includes <doctest/doctest.h> and registers TEST_CASEs. Keeping the
// implementation isolated to this file avoids recompiling doctest per test file.
#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>
