#ifndef CTPC_CTP_STDIO_H
#define CTPC_CTP_STDIO_H

/*
 * Keep the CTP SDK's own console output out of the process's raw stderr.
 *
 * The SDK libraries print through libc stdio (fprintf(stderr), printf, puts,
 * perror) and write(2) on fd 1/2. Their import slots for stderr/stdout and
 * for printf/puts/perror/write are rewritten so that this output goes
 * through the logger as "[ctp] ..." records (stdout at info, stderr at warn),
 * or is dropped. The stderr of commands the SDK runs through popen (lshw,
 * dmidecode) is discarded; their stdout still goes back to the SDK. Nothing
 * outside the patched libraries is affected: fd 2 and libc's stdio streams
 * stay as they are.
 *
 * CTPC_OUTPUT selects the mode (log|null|keep, default log). It is read
 * once, by the first ctp_stdio_init call. Only Linux x86-64 with glibc is
 * supported. On macOS (Mach-O, no ELF relocation slots to rewrite) and on
 * any other platform the output is kept as is, i.e. the module behaves like
 * CTPC_OUTPUT=keep; see docs/platform-portability.md.
 */

enum { CTP_OUTPUT_KEEP, CTP_OUTPUT_LOG, CTP_OUTPUT_NULL };

// Patch the CTP SDK libraries according to CTPC_OUTPUT. Call before
// the first CreateFtdc*Api, while no SDK thread is running.
void ctp_stdio_init(void);

// Building blocks of ctp_stdio_init, exposed for tests.
// ctp_stdio_set_mode prepares the replacement streams for LOG or NULL.
// ctp_stdio_patch rewrites the loaded object whose file name is soname and
// returns the number of slots changed, or -1 if it cannot be patched.
int ctp_stdio_parse_mode(const char *name);
void ctp_stdio_set_mode(int mode);
int ctp_stdio_patch(const char *soname);

#endif
