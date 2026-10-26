#define _POSIX_C_SOURCE 200809L

#include "log.h"

#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// One record, newline included. Matches PIPE_BUF on Linux so that a record
// written to a pipe or the journal socket is never split.
#define LOG_LINE_MAX 4096
#define LOG_TRUNCATED "..."

static const char *level_names[] = { "debug", "info", "warn", "error", "off" };
static const char *level_labels[] = { "DEBUG", "INFO ", "WARN ", "ERROR" };
// syslog priorities understood by journald: debug, info, warning, err.
static const char *journal_prefixes[] = { "<7>", "<6>", "<4>", "<3>" };
static const char *format_names[] = { "text", "journal" };

static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static int current_level = LOG_INFO;
static int current_format = LOG_FORMAT_TEXT;

static int
parse_name(const char *name, const char **names, int count) {
    if (name == NULL)
        return -1;
    for (int i = 0; i < count; i++) {
        if (strcmp(name, names[i]) == 0)
            return i;
    }
    return -1;
}

int
log_parse_level(const char *name) {
    return parse_name(name, level_names, LOG_OFF + 1);
}

int
log_parse_format(const char *name) {
    return parse_name(name, format_names, LOG_FORMAT_JOURNAL + 1);
}

const char *
log_level_name(int level) {
    return level >= LOG_DEBUG && level <= LOG_OFF ? level_names[level] : NULL;
}

const char *
log_format_name(int format) {
    return format >= LOG_FORMAT_TEXT && format <= LOG_FORMAT_JOURNAL ?
        format_names[format] : NULL;
}

static void
write_all(const char *data, size_t size) {
    while (size > 0) {
        ssize_t n = write(STDERR_FILENO, data, size);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return;
        }
        data += n;
        size -= (size_t)n;
    }
}

static size_t
append(char *buf, size_t pos, const char *s, size_t n) {
    // Keep one byte for the trailing newline.
    size_t room = LOG_LINE_MAX - 1 - pos;
    if (n > room)
        n = room;
    memcpy(buf + pos, s, n);
    return pos + n;
}

static void
emit(int level, int format, const char *file, int line,
     const char *fmt, va_list ap) {
    char message[LOG_LINE_MAX];
    char buf[LOG_LINE_MAX];
    size_t pos = 0;
    int n;

    int len = vsnprintf(message, sizeof(message), fmt, ap);
    if (len < 0)
        return;
    size_t msg_len = (size_t)len < sizeof(message) ?
        (size_t)len : sizeof(message) - 1;
    bool truncated = (size_t)len >= sizeof(message);

    const char *prefix = "";
    if (format == LOG_FORMAT_JOURNAL) {
        // journald keeps its own timestamp.
        prefix = journal_prefixes[level];
        pos = append(buf, pos, prefix, strlen(prefix));
    } else {
        struct timespec ts;
        struct tm tm;
        char stamp[32];
        clock_gettime(CLOCK_REALTIME, &ts);
        localtime_r(&ts.tv_sec, &tm);
        strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &tm);
        n = snprintf(buf, sizeof(buf), "%s.%03ld %s ",
            stamp, ts.tv_nsec / 1000000, level_labels[level]);
        pos = (size_t)n;
    }
    if (file != NULL) {
        n = snprintf(buf + pos, sizeof(buf) - 1 - pos, "%s:%d: ", file, line);
        if (n > 0)
            pos += (size_t)n < sizeof(buf) - 1 - pos ?
                (size_t)n : sizeof(buf) - 2 - pos;
    }

    // journald splits records on newlines, so every continuation line of a
    // multi-line message (e.g. a traceback) repeats the priority prefix.
    const char *p = message;
    const char *end = message + msg_len;
    while (p < end) {
        const char *nl = memchr(p, '\n', (size_t)(end - p));
        size_t chunk = nl ? (size_t)(nl - p) + 1 : (size_t)(end - p);
        size_t before = pos;
        pos = append(buf, pos, p, chunk);
        p += chunk;
        if (pos - before < chunk) {
            truncated = true;
            break;
        }
        if (nl && p < end && format == LOG_FORMAT_JOURNAL) {
            size_t prefix_len = strlen(prefix);
            before = pos;
            pos = append(buf, pos, prefix, prefix_len);
            if (pos - before < prefix_len) {
                truncated = true;
                break;
            }
        }
    }
    if (truncated) {
        size_t marker = sizeof(LOG_TRUNCATED) - 1;
        if (pos > LOG_LINE_MAX - 1 - marker)
            pos = LOG_LINE_MAX - 1 - marker;
        pos = append(buf, pos, LOG_TRUNCATED, marker);
    }
    buf[pos++] = '\n';
    write_all(buf, pos);
}

static void
emit_now(int level, const char *file, int line, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    emit(level, __atomic_load_n(&current_format, __ATOMIC_RELAXED),
        file, line, fmt, ap);
    va_end(ap);
}

static bool
stderr_is_journal(void) {
    const char *stream = getenv("JOURNAL_STREAM");
    unsigned long long dev, ino;
    struct stat st;

    if (stream == NULL || sscanf(stream, "%llu:%llu", &dev, &ino) != 2)
        return false;
    if (fstat(STDERR_FILENO, &st) != 0)
        return false;
    return (unsigned long long)st.st_dev == dev &&
        (unsigned long long)st.st_ino == ino;
}

// Runs once, before any record is written. The environment is only read
// here, so later setenv calls from other threads cannot race with getenv.
static void
log_init(void) {
    const char *level_env = getenv("SERVICE_LOG_LEVEL");
    const char *format_env = getenv("SERVICE_LOG_FORMAT");
    int level = log_parse_level(level_env);
    int format = log_parse_format(format_env);

    if (format < 0)
        format = stderr_is_journal() ? LOG_FORMAT_JOURNAL : LOG_FORMAT_TEXT;
    __atomic_store_n(&current_format, format, __ATOMIC_RELAXED);
    if (level >= 0)
        __atomic_store_n(&current_level, level, __ATOMIC_RELAXED);

    // log_write would re-enter pthread_once, so report directly.
    if (level_env != NULL && level < 0 && current_level <= LOG_WARN)
        emit_now(LOG_WARN, NULL, 0,
            "ignoring invalid SERVICE_LOG_LEVEL: %s", level_env);
    if (format_env != NULL && log_parse_format(format_env) < 0 &&
        current_level <= LOG_WARN)
        emit_now(LOG_WARN, NULL, 0,
            "ignoring invalid SERVICE_LOG_FORMAT: %s", format_env);
}

static void
ensure_init(void) {
    pthread_once(&init_once, log_init);
}

void
log_set_level(int level) {
    ensure_init();
    if (level >= LOG_DEBUG && level <= LOG_OFF)
        __atomic_store_n(&current_level, level, __ATOMIC_RELAXED);
}

void
log_set_format(int format) {
    ensure_init();
    if (format >= LOG_FORMAT_TEXT && format <= LOG_FORMAT_JOURNAL)
        __atomic_store_n(&current_format, format, __ATOMIC_RELAXED);
}

int
log_get_level(void) {
    ensure_init();
    return __atomic_load_n(&current_level, __ATOMIC_RELAXED);
}

int
log_get_format(void) {
    ensure_init();
    return __atomic_load_n(&current_format, __ATOMIC_RELAXED);
}

int
log_enabled(int level) {
    return level >= LOG_DEBUG && level < LOG_OFF && level >= log_get_level();
}

void
log_write(int level, const char *file, int line, const char *fmt, ...) {
    if (!log_enabled(level))
        return;
    int saved_errno = errno;
    va_list ap;
    va_start(ap, fmt);
    emit(level, log_get_format(), file, line, fmt, ap);
    va_end(ap);
    errno = saved_errno;
}
