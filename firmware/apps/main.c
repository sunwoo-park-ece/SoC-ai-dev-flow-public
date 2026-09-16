/*
 * Final RC Controller SoC demo firmware entry.
 *
 * Keep the implementation in final_main.c because the build/test documents and
 * historical artifacts already refer to that target. This wrapper lets the same
 * firmware also be built with:
 *
 *   ./scripts/build/build_fw.sh main
 */
#include "final_main.c"
