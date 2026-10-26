#ifndef SERVICE_LOG_H
#define SERVICE_LOG_H

/*
 * Process-wide logger. Every record is formatted into one line and written
 * to stderr with a single write(2), so records from different service
 * threads never interleave. Where stderr goes is left to whoever started
 * the process (shell redirection, systemd, ...).
 *
 * Defaults come from SERVICE_LOG_LEVEL (debug|info|warn|error|off, default
 * info) and SERVICE_LOG_FORMAT (text|journal), both case-insensitive.
 * Without SERVICE_LOG_FORMAT, journal is chosen when stderr is the stream
 * named by JOURNAL_STREAM.
 */

enum { LOG_DEBUG, LOG_INFO, LOG_WARN, LOG_ERROR, LOG_OFF };
enum { LOG_FORMAT_TEXT, LOG_FORMAT_JOURNAL };

// Return the level or format for a name, ignoring case, or -1 if the name
// is unknown.
int log_parse_level(const char *name);
int log_parse_format(const char *name);
const char *log_level_name(int level);
const char *log_format_name(int format);

void log_set_level(int level);
void log_set_format(int format);
int log_get_level(void);
int log_get_format(void);
int log_enabled(int level);

// file may be NULL to omit the location.
void log_write(int level, const char *file, int line, const char *fmt, ...)
    __attribute__((format(printf, 4, 5)));

#define log_debug(...) log_write(LOG_DEBUG, __FILE__, __LINE__, __VA_ARGS__)
#define log_info(...)  log_write(LOG_INFO,  __FILE__, __LINE__, __VA_ARGS__)
#define log_warn(...)  log_write(LOG_WARN,  __FILE__, __LINE__, __VA_ARGS__)
#define log_error(...) log_write(LOG_ERROR, __FILE__, __LINE__, __VA_ARGS__)

#endif
