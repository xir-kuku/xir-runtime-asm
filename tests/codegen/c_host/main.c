/// C host test for XIR Runtime ASM.
/// Demonstrates calling the C ABI functions and executing generated code.
///
/// Build:
///   zig build                              (produces zig-out/bin/xir_asm.dll)
///   cl /Fe:test_cg_host tests/codegen/c_host/main.c /link zig-out\bin\xir_asm.lib
///
/// Or with MSVC from the zig build output directory:
///   cl /Fe:test_cg_host ..\..\tests\codegen\c_host\main.c /link xir_asm.lib

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- DLL imports (same signature as exports) ---- */
void*   xir_new(uint32_t mode_bits);
void    xir_free(void* ctx);
uint8_t* xir_assemble(void* ctx, const char* source, size_t* out_len, int32_t* out_err);
void    xir_free_output(void* ctx);
uint64_t xir_symbol_value(void* ctx, const char* name, int32_t* found);
const char* xir_diagnostic_message(void* ctx);
const char* xir_get_listing(void* ctx);
void*   xir_asm_compile(const char* source, uint8_t mode_bits, size_t* out_size);
void    xir_asm_free(void* code);

/* ---- helpers ---- */
static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL [line %d]: %s\n", __LINE__, msg); \
        failures++; \
    } else { \
        printf("  ok: %s\n", msg); \
    } \
} while(0)

/* ---- tests ---- */

static void test_ctx_lifecycle(void) {
    printf("\n[ctx lifecycle]\n");
    void* ctx = xir_new(64);
    CHECK(ctx != NULL, "xir_new returns non-null");
    xir_free(ctx);
    CHECK(1, "xir_free no-op on valid ctx");

    xir_free(NULL);
    CHECK(1, "xir_free(null) no-op");
}

static void test_assemble_basic(void) {
    printf("\n[assemble basic]\n");
    void* ctx = xir_new(64);
    CHECK(ctx != NULL, "create ctx");

    size_t out_len;
    int32_t err;
    uint8_t* out = xir_assemble(ctx, "nop", &out_len, &err);
    CHECK(out != NULL, "assemble nop returns non-null");
    CHECK(err == 0, "error code is OK");
    CHECK(out_len == 1, "nop is 1 byte");
    CHECK(out[0] == 0x90, "nop byte is 0x90");

    xir_free_output(ctx);
    xir_free(ctx);
}

static void test_assemble_error(void) {
    printf("\n[assemble error]\n");
    void* ctx = xir_new(64);
    size_t out_len;
    int32_t err;
    uint8_t* out = xir_assemble(ctx, "bad_instruction_xyz", &out_len, &err);
    CHECK(out == NULL, "invalid instruction returns NULL");
    CHECK(err == -2, "error code is ASSEMBLY (-2)");

    const char* msg = xir_diagnostic_message(ctx);
    CHECK(msg != NULL, "diagnostic message is non-null");
    CHECK(strlen(msg) > 0, "diagnostic message not empty");
    printf("  diagnostic: %s\n", msg);

    xir_free(ctx);
}

static void test_symbol_value(void) {
    printf("\n[symbol value]\n");
    void* ctx = xir_new(64);
    size_t out_len;
    int32_t err;
    uint8_t* out = xir_assemble(ctx, "equ MAGIC = 0x42\ndb MAGIC", &out_len, &err);
    CHECK(out != NULL, "assemble equ source");
    CHECK(err == 0, "assemble equ error code is OK");

    int32_t found;
    uint64_t val = xir_symbol_value(ctx, "MAGIC", &found);
    CHECK(found == 1, "symbol found");
    CHECK(val == 0x42, "symbol value is 0x42");

    val = xir_symbol_value(ctx, "NONEXISTENT", &found);
    CHECK(found == 0, "nonexistent symbol not found");
    CHECK(val == 0, "nonexistent value is 0");

    xir_free_output(ctx);
    xir_free(ctx);
}

static void test_listing(void) {
    printf("\n[listing]\n");
    void* ctx = xir_new(64);
    size_t out_len;
    int32_t err;
    uint8_t* out = xir_assemble(ctx, "nop\nnop\nret", &out_len, &err);
    CHECK(out != NULL, "assemble listing source");
    CHECK(err == 0, "assemble listing error code is OK");

    const char* listing = xir_get_listing(ctx);
    CHECK(listing != NULL, "listing non-null");
    CHECK(strstr(listing, "nop") != NULL, "listing contains 'nop'");
    CHECK(strstr(listing, "ret") != NULL, "listing contains 'ret'");
    printf("%s\n", listing);

    xir_free_output(ctx);
    xir_free(ctx);
}

static void test_compile_execute(void) {
    printf("\n[compile and execute]\n");

    /* --- one-shot runtime assembly --- */
    size_t size;
    void* code = xir_asm_compile(
        "mov rax, 42\n"
        "ret", 64, &size);
    CHECK(code != NULL, "compile returns non-null");
    CHECK(size == 6, "mov rax,42 + ret = 6 bytes (b8 2a 00 00 00 c3)");

    /* cast to function pointer and call */
    int64_t (*fn)(void) = (int64_t (*)(void))code;
    int64_t result = fn();
    CHECK(result == 42, "execution returns 42");
    printf("  result: %lld\n", result);

    xir_asm_free(code);

    /* --- null/error cases --- */
    code = xir_asm_compile(NULL, 64, NULL);
    CHECK(code == NULL, "null source returns NULL");

    code = xir_asm_compile("invalid_instruction", 64, NULL);
    CHECK(code == NULL, "invalid source returns NULL");

    xir_asm_free(NULL);
    CHECK(1, "free(null) no-op");
}

static void test_compile_with_args(void) {
    printf("\n[compile with arguments]\n");

    /*
     * Windows x64 calling convention: 1st arg = RCX, 2nd arg = RDX.
     * System V x86-64 calling convention: 1st arg = RDI, 2nd arg = RSI.
     */
    void* code = xir_asm_compile(
#ifdef _WIN32
        "mov rax, rcx\n"
        "add rax, rdx\n"
#else
        "mov rax, rdi\n"
        "add rax, rsi\n"
#endif
        "ret", 64, NULL);
    CHECK(code != NULL, "compile with args returns non-null");

    int64_t (*add_fn)(int64_t, int64_t) = (int64_t (*)(int64_t, int64_t))code;
    int64_t sum = add_fn(10, 20);
    CHECK(sum == 30, "10 + 20 = 30");

    sum = add_fn(-5, 5);
    CHECK(sum == 0, "-5 + 5 = 0");

    xir_asm_free(code);
}

static void test_stateful_assemble_then_execute(void) {
    printf("\n[stateful assemble then execute]\n");
    void* ctx = xir_new(32);

    /* assemble "mov eax, 0x42; ret" */
    size_t out_len;
    uint8_t* out = xir_assemble(ctx,
        "mov eax, 0x42\nret", &out_len, NULL);
    CHECK(out != NULL, "assemble returns non-null");
    CHECK(out_len == 6, "mov eax,imm32 + ret = 6 bytes");

    /* compile the same source into executable memory */
    void* code = xir_asm_compile(
        "mov eax, 0x42\nret", 32, NULL);
    CHECK(code != NULL, "compile of same source");

    int32_t (*fn)(void) = (int32_t (*)(void))code;
    int32_t val = fn();
    CHECK(val == 0x42, "execution returns 0x42");

    xir_free_output(ctx);
    xir_free(ctx);
    xir_asm_free(code);
}

/* ---- main ---- */

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    printf("XIR Runtime ASM C host test\n");
    printf("=====================\n");

    test_ctx_lifecycle();
    test_assemble_basic();
    test_assemble_error();
    test_symbol_value();
    test_listing();
    test_compile_execute();
    test_compile_with_args();
    test_stateful_assemble_then_execute();

    printf("\n=====================\n");
    if (failures) {
        printf("FAILED: %d test(s)\n", failures);
        return 1;
    }
    printf("All tests passed.\n");
    return 0;
}
