/* Valgrind client requests that bracket a measured phase.

   Compiled into a tiny shared library and called from the harness via
   ctypes. The instruction sequence is a no-op when the process is not
   running under Callgrind, so the same harness can be launched natively.
*/
#include <valgrind/callgrind.h>

void baseline_start(void) { CALLGRIND_START_INSTRUMENTATION; }

void baseline_stop(void) { CALLGRIND_STOP_INSTRUMENTATION; }

void baseline_dump(const char *label) { CALLGRIND_DUMP_STATS_AT(label); }
