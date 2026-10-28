/*
 * ctp_stdio_test <fake-lib> lazy|now
 *     Patch a fake SDK library and check where each kind of output lands.
 * ctp_stdio_test --sdk <lib> <expected-slots>
 *     Patch a real SDK library and check the number of slots changed.
 */
#define _GNU_SOURCE

#include "ctp_stdio.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures;

#define CHECK(cond, ...) do { \
        if (!(cond)) { \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__); \
            fputc('\n', stderr); \
            failures++; \
        } \
    } while (0)

static const char *
base_name(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash != NULL ? slash + 1 : path;
}

static void *
open_library(const char *path, int flags) {
    void *h = dlopen(path, flags);
    if (h == NULL) {
        fprintf(stderr, "dlopen %s: %s\n", path, dlerror());
        exit(2);
    }
    return h;
}

static int
count(const char *haystack, const char *needle) {
    int n = 0;
    for (const char *p = haystack; (p = strstr(p, needle)) != NULL; p++)
        n++;
    return n;
}

static int
test_sdk(const char *path, int expected) {
    open_library(path, RTLD_NOW);
    ctp_stdio_set_mode(CTP_OUTPUT_LOG);
    int n = ctp_stdio_patch(base_name(path));
    CHECK(n == expected, "%s: %d slots patched, expected %d", path, n, expected);
    if (failures == 0)
        printf("ctp_stdio_test: %s: %d slots ok\n", base_name(path), n);
    return failures ? 1 : 0;
}

static int
test_fake(const char *path, const char *bind) {
    void *h = open_library(path, strcmp(bind, "now") == 0 ? RTLD_NOW : RTLD_LAZY);
    void (*fake_emit)(int) = (void (*)(int))dlsym(h, "fake_emit");
    CHECK(fake_emit != NULL, "fake_emit not found");
    if (fake_emit == NULL)
        return 1;

    // Capture fd 1 and fd 2; output to any other fd must pass through.
    char capture_path[] = "/tmp/ctp_stdio_test.XXXXXX";
    int capture = mkstemp(capture_path);
    int other[2];
    if (capture < 0 || pipe(other) != 0)
        return 2;
    unlink(capture_path);
    int saved_out = dup(STDOUT_FILENO), saved_err = dup(STDERR_FILENO);
    fflush(NULL);
    dup2(capture, STDOUT_FILENO);
    dup2(capture, STDERR_FILENO);

    ctp_stdio_set_mode(CTP_OUTPUT_LOG);
    int patched = ctp_stdio_patch(base_name(path));
    fake_emit(other[1]);
    // The process's own output is not touched.
    fprintf(stderr, "own fprintf\n");
    write(STDERR_FILENO, "own write\n", 10);
    // Dropped entirely in null mode, apart from other fds.
    ctp_stdio_set_mode(CTP_OUTPUT_NULL);
    fake_emit(other[1]);

    fflush(NULL);
    dup2(saved_out, STDOUT_FILENO);
    dup2(saved_err, STDERR_FILENO);
    close(other[1]);

    char out[16384] = "", piped[512] = "";
    ssize_t n = pread(capture, out, sizeof(out) - 1, 0);
    out[n > 0 ? n : 0] = '\0';
    n = read(other[0], piped, sizeof(piped) - 1);
    piped[n > 0 ? n : 0] = '\0';

    CHECK(patched == 7, "%d slots patched, expected 7", patched);
    static const char *expected[] = {
        "WARN  [ctp] fake fprintf 1\n",
        "WARN  [ctp] fake fputs\n",
        "WARN  [ctp] fake fwrite\n",
        "WARN  [ctp] X fake fputc\n",
        "INFO  [ctp] fake printf out\n",
        "INFO  [ctp] fake puts\n",
        "WARN  [ctp] fake perror: No such file or directory\n",
        "WARN  [ctp] fake write2\n",
        "INFO  [ctp] fake write1\n",
    };
    for (size_t i = 0; i < sizeof(expected) / sizeof(expected[0]); i++)
        CHECK(count(out, expected[i]) == 1, "expected once: %s", expected[i]);
    // Every fake line is a logger record; none leaked raw or in null mode.
    CHECK(count(out, "fake ") == 9, "fake lines: %d, expected 9", count(out, "fake "));
    CHECK(count(out, "fake_no_such_command") == 0, "popen shell error leaked");
    CHECK(count(out, "\nfake ") == 0 && strncmp(out, "fake ", 5) != 0,
        "raw SDK output leaked");
    CHECK(count(out, "own fprintf\n") == 1 && count(out, "own write\n") == 1,
        "process output changed");
    CHECK(strcmp(piped, "fake other\nfake popen out\nfake other\nfake popen out\n") == 0,
        "other fd: %s", piped);

    if (failures)
        fprintf(stderr, "--- captured output ---\n%s", out);
    else
        printf("ctp_stdio_test: %s (%s): ok\n", base_name(path), bind);
    return failures ? 1 : 0;
}

int
main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "--sdk") == 0)
        return test_sdk(argv[2], atoi(argv[3]));
    if (argc == 3)
        return test_fake(argv[1], argv[2]);
    fprintf(stderr, "usage: %s <fake-lib> lazy|now | --sdk <lib> <slots>\n", argv[0]);
    return 2;
}
