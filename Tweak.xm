#include <unistd.h>
#include <fcntl.h>
#include <string.h>

__attribute__((constructor))
static void test_init(void) {
    int fd = open("/tmp/procguard_loaded.txt", O_WRONLY|O_CREAT|O_TRUNC, 0644);
    if (fd >= 0) {
        const char *msg = "ProcGuard minimal test loaded\n";
        write(fd, msg, strlen(msg));
        close(fd);
    }
}
