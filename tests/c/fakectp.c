// Stand-in for a CTP SDK library: prints through every path the real ones
// use. Built with -fno-builtin so each call stays the libc function named.
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

void
fake_emit(int other_fd) {
    fprintf(stderr, "fake fprintf %d\n", 1);
    fputs("fake fputs\n", stderr);
    fwrite("fake fwrite\n", 1, 12, stderr);
    fputc('X', stderr);
    fputs(" fake fputc\n", stderr);
    printf("fake printf %s\n", "out");
    puts("fake puts");
    errno = ENOENT;
    perror("fake perror");
    write(STDERR_FILENO, "fake write2\n", 12);
    write(STDOUT_FILENO, "fake write1\n", 12);
    write(other_fd, "fake other\n", 11);
    // Like the SDK's terminal-info probes: stdout is read back, stderr and the
    // shell's "not found" must not reach fd 2.
    FILE *p = popen("echo fake popen out; echo fake popen err >&2;"
        " fake_no_such_command | cat", "r");
    char line[64];
    while (p != NULL && fgets(line, sizeof(line), p) != NULL)
        write(other_fd, line, strlen(line));
    if (p != NULL)
        pclose(p);
    fflush(stdout);
}
