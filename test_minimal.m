#include <stdio.h>
#include <time.h>

__attribute__((constructor))
static void test_init(void) {
    FILE *fp = fopen("/tmp/procguard_test.txt", "w");
    if (fp) {
        fprintf(fp, "test loaded at %ld\n", (long)time(NULL));
        fclose(fp);
    }
}
