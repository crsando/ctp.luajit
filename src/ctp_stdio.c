#define _GNU_SOURCE

#include "ctp_stdio.h"
#include "log.h"

#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#if defined(__GLIBC__) && defined(__x86_64__)
#define CTP_STDIO_SUPPORTED 1
#include <elf.h>
#include <link.h>
#include <sys/mman.h>
// The SDK libraries whose output is redirected.
static const char *ctp_libraries[] = {
    "libthostmduserapi_se.so",
    "libthosttraderapi_se.so",
};
#elif defined(__APPLE__)
// Mach-O has no ELF relocation slots to rewrite; the SDK's output is kept as
// is. This is a known limitation, not a failure, so it is logged at info.
#define CTP_STDIO_MACHO 1
#endif

// Matched case-insensitively, like the logger's level names.
static const char *mode_names[] = { "keep", "log", "null" };

int
ctp_stdio_parse_mode(const char *name) {
    for (int i = 0; i <= CTP_OUTPUT_NULL; i++) {
        if (name != NULL && strcasecmp(name, mode_names[i]) == 0)
            return i;
    }
    return -1;
}

#ifdef CTP_STDIO_SUPPORTED

/*
 * Replacement streams. Every write the SDK makes ends up in one of these two
 * FILEs, so the FILE lock serializes access to the line buffer. Lines are
 * assembled here and handed to the logger one record at a time.
 */

// Leave room for the logger's own prefix within its 4096-byte record.
#define CTP_LINE_MAX 3072

struct line_sink {
    int level;
    size_t len;
    char buf[CTP_LINE_MAX];
};

static struct line_sink out_sink = { .level = LOG_INFO };
static struct line_sink err_sink = { .level = LOG_WARN };
static FILE *ctp_out;
static FILE *ctp_err;
static int output_mode = CTP_OUTPUT_KEEP;

static void
sink_flush(struct line_sink *s) {
    if (s->len > 0)
        log_write(s->level, NULL, 0, "[ctp] %.*s", (int)s->len, s->buf);
    s->len = 0;
}

static ssize_t
sink_write(void *cookie, const char *data, size_t size) {
    struct line_sink *s = cookie;

    if (__atomic_load_n(&output_mode, __ATOMIC_RELAXED) != CTP_OUTPUT_LOG)
        return (ssize_t)size;
    for (size_t i = 0; i < size; i++) {
        char c = data[i];
        if (c == '\n') {
            sink_flush(s);
            continue;
        }
        if (c == '\r')
            continue;
        if (s->len == sizeof(s->buf))
            sink_flush(s);
        s->buf[s->len++] = c;
    }
    return (ssize_t)size;
}

static FILE *
open_sink(struct line_sink *s) {
    cookie_io_functions_t io = { .write = sink_write };
    FILE *f = fopencookie(s, "w", io);
    // Unbuffered: line assembly happens in the sink, so nothing waits in
    // the FILE for a flush that may never come.
    if (f != NULL)
        setvbuf(f, NULL, _IONBF, 0);
    return f;
}

void
ctp_stdio_set_mode(int mode) {
    if (mode != CTP_OUTPUT_LOG && mode != CTP_OUTPUT_NULL)
        return;
    if (ctp_out == NULL)
        ctp_out = open_sink(&out_sink);
    if (ctp_err == NULL)
        ctp_err = open_sink(&err_sink);
    __atomic_store_n(&output_mode, mode, __ATOMIC_RELAXED);
}

/*
 * Replacements for the libc functions that print without taking a FILE from
 * the SDK's own stderr/stdout slots. Calls made from here go through this
 * library's import slots, which are never patched, so they reach libc.
 */

static int hook_printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

static int
hook_printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vfprintf(ctp_out, fmt, ap);
    va_end(ap);
    return n;
}

static int
hook_puts(const char *s) {
    if (fputs(s, ctp_out) == EOF || fputc('\n', ctp_out) == EOF)
        return EOF;
    return 1;
}

static void
hook_perror(const char *s) {
    int saved_errno = errno;
    char buf[128];
    const char *msg = strerror_r(saved_errno, buf, sizeof(buf));
    if (s != NULL && *s != '\0')
        fprintf(ctp_err, "%s: %s\n", s, msg);
    else
        fprintf(ctp_err, "%s\n", msg);
    errno = saved_errno;
}

static ssize_t
hook_write(int fd, const void *data, size_t size) {
    if (fd == STDOUT_FILENO || fd == STDERR_FILENO)
        return (ssize_t)fwrite(data, 1, size,
            fd == STDOUT_FILENO ? ctp_out : ctp_err);
    return write(fd, data, size);
}

/*
 * The SDK shells out to collect terminal info for regulatory reporting
 * (lshw, dmidecode). It reads the commands' stdout; their stderr would go
 * straight to fd 2, past every slot patched here, so it is discarded. The
 * braces apply the redirection to the whole pipeline and to the shell's own
 * "not found" messages.
 */
static FILE *
hook_popen(const char *command, const char *type) {
    if (command == NULL)
        return popen(command, type);
    if (__atomic_load_n(&output_mode, __ATOMIC_RELAXED) == CTP_OUTPUT_LOG)
        log_debug("[ctp] popen: %s", command);

    size_t size = strlen(command) + sizeof("{ \n} 2>/dev/null");
    char *wrapped = malloc(size);
    if (wrapped == NULL)
        return popen(command, type);
    snprintf(wrapped, size, "{ %s\n} 2>/dev/null", command);
    FILE *f = popen(wrapped, type);
    int saved_errno = errno;
    free(wrapped);
    errno = saved_errno;
    return f;
}

/*
 * Slot patching. A GLOB_DAT slot for stderr/stdout holds the address of
 * libc's FILE * variable; pointing it at ctp_err/ctp_out redirects every
 * fprintf/fputs/fwrite/fputc/vfprintf the SDK makes on that stream. Function
 * slots (JUMP_SLOT, or GLOB_DAT when the address is taken) get the hooks.
 */

struct target {
    const char *name;
    void *value;
};

struct object {
    ElfW(Addr) base;
    uintptr_t relro_start; // page-aligned range the loader made read-only
    uintptr_t relro_end;
    const ElfW(Sym) *symtab;
    const char *strtab;
};

static void *
target_value(const struct target *targets, size_t count, const char *name) {
    for (size_t i = 0; i < count; i++) {
        if (strcmp(targets[i].name, name) == 0)
            return targets[i].value;
    }
    return NULL;
}

static bool
store_slot(const struct object *obj, void **slot, void *value) {
    uintptr_t page_size = (uintptr_t)sysconf(_SC_PAGESIZE);
    uintptr_t page = (uintptr_t)slot & ~(page_size - 1);
    bool read_only = page >= obj->relro_start && page < obj->relro_end;

    if (read_only && mprotect((void *)page, page_size, PROT_READ | PROT_WRITE) != 0)
        return false;
    __atomic_store_n(slot, value, __ATOMIC_RELEASE);
    if (read_only)
        mprotect((void *)page, page_size, PROT_READ);
    return true;
}

// Returns the number of slots changed, or -1 on failure.
static int
patch_relocs(const struct object *obj, const ElfW(Rela) *rela, size_t size,
             const struct target *targets, size_t count) {
    int patched = 0;
    for (size_t i = 0; rela != NULL && i < size / sizeof(*rela); i++) {
        unsigned type = ELF64_R_TYPE(rela[i].r_info);
        unsigned sym = ELF64_R_SYM(rela[i].r_info);
        if (sym == 0 || rela[i].r_addend != 0)
            continue;
        if (type != R_X86_64_GLOB_DAT && type != R_X86_64_JUMP_SLOT &&
            type != R_X86_64_64)
            continue;
        void *value = target_value(targets, count,
            obj->strtab + obj->symtab[sym].st_name);
        if (value == NULL)
            continue;
        if (!store_slot(obj, (void **)(obj->base + rela[i].r_offset), value))
            return -1;
        patched++;
    }
    return patched;
}

static int
patch_object(struct dl_phdr_info *info) {
    const struct target targets[] = {
        { "stdout", &ctp_out },
        { "stderr", &ctp_err },
        { "printf", (void *)hook_printf },
        { "puts", (void *)hook_puts },
        { "perror", (void *)hook_perror },
        { "write", (void *)hook_write },
        { "popen", (void *)hook_popen },
    };
    size_t count = sizeof(targets) / sizeof(targets[0]);
    uintptr_t page_size = (uintptr_t)sysconf(_SC_PAGESIZE);
    struct object obj = { .base = info->dlpi_addr };
    const ElfW(Dyn) *dyn = NULL;

    for (int i = 0; i < info->dlpi_phnum; i++) {
        const ElfW(Phdr) *ph = &info->dlpi_phdr[i];
        if (ph->p_type == PT_DYNAMIC)
            dyn = (const ElfW(Dyn) *)(obj.base + ph->p_vaddr);
        if (ph->p_type == PT_GNU_RELRO) {
            // Same rounding as the loader: a partial last page stays writable.
            obj.relro_start = (obj.base + ph->p_vaddr) & ~(page_size - 1);
            obj.relro_end = (obj.base + ph->p_vaddr + ph->p_memsz) & ~(page_size - 1);
        }
    }
    if (dyn == NULL)
        return -1;

    const ElfW(Rela) *rela = NULL, *jmprel = NULL;
    size_t rela_size = 0, jmprel_size = 0;
    ElfW(Sxword) pltrel = DT_RELA;
    for (const ElfW(Dyn) *d = dyn; d->d_tag != DT_NULL; d++) {
        // glibc rewrites these to absolute addresses on load; accept both.
        ElfW(Addr) ptr = d->d_un.d_ptr < obj.base ?
            d->d_un.d_ptr + obj.base : d->d_un.d_ptr;
        switch (d->d_tag) {
        case DT_SYMTAB:   obj.symtab = (const ElfW(Sym) *)ptr; break;
        case DT_STRTAB:   obj.strtab = (const char *)ptr; break;
        case DT_RELA:     rela = (const ElfW(Rela) *)ptr; break;
        case DT_RELASZ:   rela_size = d->d_un.d_val; break;
        case DT_JMPREL:   jmprel = (const ElfW(Rela) *)ptr; break;
        case DT_PLTRELSZ: jmprel_size = d->d_un.d_val; break;
        case DT_PLTREL:   pltrel = d->d_un.d_val; break;
        }
    }
    if (obj.symtab == NULL || obj.strtab == NULL || pltrel != DT_RELA)
        return -1;

    int a = patch_relocs(&obj, rela, rela_size, targets, count);
    int b = patch_relocs(&obj, jmprel, jmprel_size, targets, count);
    return a < 0 || b < 0 ? -1 : a + b;
}

struct search {
    const char *soname;
    int result;
};

static int
find_object(struct dl_phdr_info *info, size_t size, void *data) {
    struct search *s = data;
    const char *name = strrchr(info->dlpi_name, '/');
    name = name != NULL ? name + 1 : info->dlpi_name;
    if (strcmp(name, s->soname) != 0)
        return 0;
    s->result = patch_object(info);
    return 1;
}

int
ctp_stdio_patch(const char *soname) {
    struct search s = { soname, -1 };
    if (ctp_out == NULL || ctp_err == NULL)
        return -1;
    dl_iterate_phdr(find_object, &s);
    return s.result;
}

#else

void
ctp_stdio_set_mode(int mode) {
}

int
ctp_stdio_patch(const char *soname) {
    return -1;
}

#endif

static pthread_once_t init_once = PTHREAD_ONCE_INIT;

static void
init(void) {
#ifdef CTP_STDIO_MACHO
    // Nothing to patch on Mach-O. Say so once at info rather than warning on
    // every start: the output being kept is the documented macOS behaviour.
    // CTPC_OUTPUT is not read at all here, so an invalid value is not
    // reported either.

    log_info("ctp stdio | macOS: SDK output is kept as is (see docs/logging.md)");
    return;
#else
    const char *env = getenv("CTPC_OUTPUT");
    int mode = env != NULL ? ctp_stdio_parse_mode(env) : CTP_OUTPUT_LOG;

    if (mode < 0) {
        log_warn("ignoring invalid CTPC_OUTPUT: %s", env);
        mode = CTP_OUTPUT_LOG;
    }
    if (mode == CTP_OUTPUT_KEEP)
        return;
    ctp_stdio_set_mode(mode);
    for (size_t i = 0; i < sizeof(ctp_libraries) / sizeof(ctp_libraries[0]); i++) {
        int n = ctp_stdio_patch(ctp_libraries[i]);
        if (n > 0)
            log_debug("ctp stdio | %s | %d slots redirected", ctp_libraries[i], n);
        else
            log_warn("ctp stdio | %s | output not redirected (%d)", ctp_libraries[i], n);
    }
#endif
}

void
ctp_stdio_init(void) {
    pthread_once(&init_once, init);
}
