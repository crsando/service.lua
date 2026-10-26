#define _POSIX_C_SOURCE 200809L

#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "log.h"

#define WRITERS 8
#define LINES_PER_WRITER 2000

// Redirects stderr into a fresh temporary file for one check.
static FILE *capture;
static int saved_stderr;

static void
capture_begin(void) {
    fflush(stderr);
    capture = tmpfile();
    assert(capture != NULL);
    saved_stderr = dup(STDERR_FILENO);
    assert(saved_stderr >= 0);
    assert(dup2(fileno(capture), STDERR_FILENO) >= 0);
}

static void
capture_end(void) {
    assert(dup2(saved_stderr, STDERR_FILENO) >= 0);
    close(saved_stderr);
    rewind(capture);
}

static void *
write_lines(void *data) {
    int writer = (int)(intptr_t)data;
    for (int i = 0; i < LINES_PER_WRITER; i++)
        log_write(LOG_INFO, NULL, 0, "writer=%d seq=%d %s", writer, i,
            "padding padding padding padding padding padding padding");
    return NULL;
}

// Every record from concurrent writers comes out as one intact line.
static void
test_concurrent_lines(void) {
    pthread_t threads[WRITERS];
    int next[WRITERS] = { 0 };
    char line[512];
    int count = 0;

    log_set_format(LOG_FORMAT_TEXT);
    capture_begin();
    for (int i = 0; i < WRITERS; i++)
        assert(pthread_create(&threads[i], NULL, write_lines,
            (void *)(intptr_t)i) == 0);
    for (int i = 0; i < WRITERS; i++)
        assert(pthread_join(threads[i], NULL) == 0);
    capture_end();

    while (fgets(line, sizeof(line), capture) != NULL) {
        int writer, seq;
        const char *body = strstr(line, "INFO  writer=");
        assert(body != NULL);
        assert(sscanf(body, "INFO  writer=%d seq=%d", &writer, &seq) == 2);
        assert(writer >= 0 && writer < WRITERS);
        assert(seq == next[writer]);
        assert(strstr(body, "padding\n") != NULL);
        next[writer]++;
        count++;
    }
    assert(count == WRITERS * LINES_PER_WRITER);
    fclose(capture);
}

static void
test_level_and_journal(void) {
    char out[256];
    size_t n;

    log_set_level(LOG_WARN);
    log_set_format(LOG_FORMAT_JOURNAL);
    capture_begin();
    log_write(LOG_INFO, NULL, 0, "hidden");
    log_write(LOG_ERROR, "f.c", 7, "first\nsecond");
    log_write(LOG_WARN, NULL, 0, "warned");
    log_set_level(LOG_OFF);
    log_write(LOG_ERROR, NULL, 0, "silenced");
    capture_end();

    n = fread(out, 1, sizeof(out) - 1, capture);
    out[n] = '\0';
    assert(strcmp(out, "<3>f.c:7: first\n<3>second\n<4>warned\n") == 0);
    fclose(capture);

    log_set_level(LOG_INFO);
    log_set_format(LOG_FORMAT_TEXT);
}

static void
test_truncation(void) {
    static char big[10000];
    static char out[10000];
    size_t n;

    memset(big, 'x', sizeof(big) - 1);
    log_set_format(LOG_FORMAT_JOURNAL);
    capture_begin();
    log_write(LOG_ERROR, NULL, 0, "%s", big);
    capture_end();

    n = fread(out, 1, sizeof(out), capture);
    assert(n == 4096);
    assert(memcmp(out + n - 4, "...\n", 4) == 0);
    fclose(capture);
    log_set_format(LOG_FORMAT_TEXT);
}

static void
test_names(void) {
    assert(log_parse_level("warn") == LOG_WARN);
    assert(log_parse_level("off") == LOG_OFF);
    assert(log_parse_level("verbose") == -1);
    assert(log_parse_format("journal") == LOG_FORMAT_JOURNAL);
    assert(log_parse_format(NULL) == -1);
    assert(strcmp(log_level_name(LOG_ERROR), "error") == 0);
}

int
main(void) {
    test_names();
    test_concurrent_lines();
    test_level_and_journal();
    test_truncation();
    printf("log_test: ok\n");
    return 0;
}
