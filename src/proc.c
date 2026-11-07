// The C layer of the process package. It starts a child, reads its output
// and waits for it. The header under vendor/ does the work.
#define _GNU_SOURCE 1
#include "goose.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#endif

#include "vendor/subprocess.h"

// A slice of bytes that arrives from Goose.
typedef struct { const uint8_t *data; int64_t len; } proc_slice;

// The status values that this layer returns.
#define PROC_ENDED 0
#define PROC_NOT_STARTED 1
#define PROC_STOPPED 2
#define PROC_REFUSED 3

// The child gets at most this many arguments. The name of the program is
// one of them.
#define PROC_MAX_ARGS 64

// The child gets at most this many environment entries.
#define PROC_MAX_ENV 256

// A growable list of strings that this layer owns.
struct proc_list {
    char **items;
    int count;
    int cap;
};

static void proc_list_init(struct proc_list *list) {
    list->items = NULL;
    list->count = 0;
    list->cap = 0;
}

static void proc_list_free(struct proc_list *list) {
    for (int i = 0; i < list->count; i++) free(list->items[i]);
    free(list->items);
    list->items = NULL;
    list->count = 0;
    list->cap = 0;
}

static int proc_list_push(struct proc_list *list, char *owned) {
    // One slot stays free, so the list always ends with a null.
    if (list->count + 1 >= list->cap) {
        int cap = list->cap ? list->cap * 2 : 32;
        char **items = (char **)realloc(list->items, (size_t)cap * sizeof(char *));
        if (!items) return 0;
        list->items = items;
        list->cap = cap;
    }
    list->items[list->count++] = owned;
    list->items[list->count] = NULL;
    return 1;
}

// A copy of a string of a known length.
static char *proc_copy(const char *text, size_t len) {
    char *out = (char *)malloc(len + 1);
    if (!out) return NULL;
    memcpy(out, text, len);
    out[len] = '\0';
    return out;
}

// The name of an environment entry ends at its first equals sign.
static size_t proc_name_len(const char *entry, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if (entry[i] == '=') return i;
    }
    return len;
}

#ifdef _WIN32
// The order of two entries of the environment. Windows wants the block
// sorted by name.
static int proc_env_cmp(const void *left, const void *right) {
    const char *a = *(const char *const *)left;
    const char *b = *(const char *const *)right;
    while (*a && *a != '=' && *b && *b != '=') {
        char x = *a++;
        char y = *b++;
        if (x >= 'A' && x <= 'Z') x = (char)(x - 'A' + 'a');
        if (y >= 'A' && y <= 'Z') y = (char)(y - 'A' + 'a');
        if (x != y) return (x < y) ? -1 : 1;
    }
    return 0;
}

// Two names of the environment. Windows ignores the case of a name.
static int proc_same_name(const char *a, size_t a_len, const char *b, size_t b_len) {
    if (a_len != b_len) return 0;
    for (size_t i = 0; i < a_len; i++) {
        char x = a[i];
        char y = b[i];
        if (x >= 'A' && x <= 'Z') x = (char)(x - 'A' + 'a');
        if (y >= 'A' && y <= 'Z') y = (char)(y - 'A' + 'a');
        if (x != y) return 0;
    }
    return 1;
}
#else
static int proc_same_name(const char *a, size_t a_len, const char *b, size_t b_len) {
    return a_len == b_len && 0 == memcmp(a, b, a_len);
}
#endif

// Set one environment entry. It replaces the entry of the same name, or it
// joins the list.
static void proc_env_set(struct proc_list *list, const char *entry, size_t len) {
    size_t name_len = proc_name_len(entry, len);
    for (int i = 0; i < list->count; i++) {
        const char *cur = list->items[i];
        size_t cur_len = proc_name_len(cur, strlen(cur));
        if (!proc_same_name(cur, cur_len, entry, name_len)) continue;
        char *copy = proc_copy(entry, len);
        if (!copy) return;
        free(list->items[i]);
        list->items[i] = copy;
        return;
    }
    char *copy = proc_copy(entry, len);
    if (copy) proc_list_push(list, copy);
}

// The environment of the parent. The child gets it, plus the entries that
// the caller gave.
static void proc_load_parent_env(struct proc_list *list) {
#ifdef _WIN32
    LPCH block = GetEnvironmentStringsA();
    if (!block) return;
    const char *p = block;
    while (*p) {
        size_t len = strlen(p);
        char *copy = proc_copy(p, len);
        if (copy) proc_list_push(list, copy);
        p += len + 1;
    }
    FreeEnvironmentStringsA(block);
#else
    extern char **environ;
    if (!environ) return;
    for (int i = 0; environ[i]; i++) {
        char *copy = proc_copy(environ[i], strlen(environ[i]));
        if (copy) proc_list_push(list, copy);
    }
#endif
}

// The time in milliseconds. The clock does not jump.
static int64_t proc_now_ms(void) {
#ifdef _WIN32
    return (int64_t)GetTickCount64();
#else
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000 + (int64_t)now.tv_nsec / 1000000;
#endif
}

// Wait for the output of the child. It ends early when the child writes.
// The wait is short, so the clock of the run stays close.
static void proc_wait(int fd) {
#ifdef _WIN32
    Sleep(1);
#else
    struct pollfd entry;
    entry.fd = fd;
    entry.events = POLLIN;
    entry.revents = 0;
    poll(&entry, 1, 1);
#endif
}

// The writer of the input of the child. It runs in its own thread, so a
// child that writes much never waits for the parent.
struct proc_writer {
    FILE *file;
    const uint8_t *data;
    int64_t len;
    // The parent sets this when the child ends. The writer then gives up.
    volatile int stop;
};

#ifdef _WIN32
static DWORD WINAPI proc_write_thread(LPVOID arg) {
    struct proc_writer *writer = (struct proc_writer *)arg;
    int64_t done = 0;
    while (done < writer->len && !writer->stop) {
        size_t chunk = (size_t)(writer->len - done);
        if (chunk > 4096) chunk = 4096;
        size_t wrote = fwrite(writer->data + done, 1, chunk, writer->file);
        done += (int64_t)wrote;
        if (wrote == 0) break;
    }
    fclose(writer->file);
    return 0;
}
#else
static void *proc_write_thread(void *arg) {
    struct proc_writer *writer = (struct proc_writer *)arg;
    // A write to a closed pipe must not kill the parent.
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &set, NULL);
    // The write never waits. A child that does not read the input cannot
    // hold the parent here.
    int fd = fileno(writer->file);
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int64_t done = 0;
    while (done < writer->len && !writer->stop) {
        ssize_t wrote = write(fd, writer->data + done, (size_t)(writer->len - done));
        if (wrote > 0) {
            done += (int64_t)wrote;
            continue;
        }
        if (wrote < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd entry;
            entry.fd = fd;
            entry.events = POLLOUT;
            entry.revents = 0;
            poll(&entry, 1, 1);
            continue;
        }
        break;
    }
    fclose(writer->file);
    return NULL;
}
#endif

// The flat buffer holds a count and then the items of a section. A count is
// a decimal number and a newline. An item is bytes and a NUL.
static const char *proc_read_count(const char *at, const char *end, long *out) {
    long value = 0;
    while (at < end && *at >= '0' && *at <= '9') {
        value = value * 10 + (*at - '0');
        at++;
    }
    if (at < end && *at == '\n') at++;
    *out = value;
    return at;
}

// Read one item. It ends at its NUL byte. It fails when the item has no
// NUL byte before the end of the buffer.
static int proc_read_item(const char **at, const char *end, const char **out) {
    const char *start = *at;
    const char *p = start;
    while (p < end && *p != '\0') p++;
    if (p >= end) return 0;
    *out = start;
    *at = p + 1;
    return 1;
}

// Start a program and wait for it. The flat buffer holds the arguments, the
// environment and the directory. It returns the status of the run and it
// fills the exit code.
int32_t proc_run(proc_slice spec, proc_slice input, gs_rref out, int32_t *code,
                 int32_t timeout_ms) {
    const char *at = (const char *)spec.data;
    const char *end = at + spec.len;

    long argc = 0;
    at = proc_read_count(at, end, &argc);
    if (argc < 1 || argc > PROC_MAX_ARGS) return PROC_REFUSED;

    const char *args[PROC_MAX_ARGS + 1];
    for (long i = 0; i < argc; i++) {
        if (!proc_read_item(&at, end, &args[i])) return PROC_REFUSED;
    }
    args[argc] = NULL;

    long envc = 0;
    at = proc_read_count(at, end, &envc);
    if (envc < 0 || envc > PROC_MAX_ENV) return PROC_REFUSED;

    const char *entries[PROC_MAX_ENV];
    for (long i = 0; i < envc; i++) {
        if (!proc_read_item(&at, end, &entries[i])) return PROC_REFUSED;
    }

    const char *cwd = NULL;
    if (!proc_read_item(&at, end, &cwd)) return PROC_REFUSED;

    // The child gets the environment of the parent, plus the entries that
    // the caller gave. Without an entry the child inherits the environment.
    struct proc_list env;
    proc_list_init(&env);
    int options = subprocess_option_combined_stdout_stderr |
                  subprocess_option_enable_async |
                  subprocess_option_enable_async_no_wait |
                  subprocess_option_search_user_path;
    const char *const *env_ptr = NULL;
    if (envc > 0) {
        proc_load_parent_env(&env);
        for (long i = 0; i < envc; i++) {
            proc_env_set(&env, entries[i], strlen(entries[i]));
        }
#ifdef _WIN32
        // Windows wants the block sorted by name.
        qsort(env.items, (size_t)env.count, sizeof(char *), proc_env_cmp);
#endif
        env_ptr = (const char *const *)env.items;
    } else {
        options |= subprocess_option_inherit_environment;
    }

    struct subprocess_s child;
    const char *cwd_ptr = (cwd && cwd[0]) ? cwd : NULL;
    int created = subprocess_create_ex(args, options, env_ptr, cwd_ptr, &child);
    if (created != 0) {
        proc_list_free(&env);
        return PROC_NOT_STARTED;
    }

    // The thread writes the input. The header must not close that file, so
    // the null goes in before the thread starts.
    FILE *stdin_file = subprocess_stdin(&child);
    child.stdin_file = SUBPROCESS_NULL;
    struct proc_writer writer;
    writer.file = stdin_file;
    writer.data = input.data;
    writer.len = input.len;
    writer.stop = 0;
    int has_thread = 0;
#ifdef _WIN32
    HANDLE thread = NULL;
#else
    pthread_t thread;
#endif
    if (input.len == 0) {
        // The child needs no input. It sees the end of the input at once.
        fclose(stdin_file);
    } else {
#ifdef _WIN32
        thread = CreateThread(NULL, 0, proc_write_thread, &writer, 0, NULL);
        if (thread) has_thread = 1;
#else
        if (0 == pthread_create(&thread, NULL, proc_write_thread, &writer)) has_thread = 1;
#endif
        if (!has_thread) {
            // The thread did not start. The parent writes the input itself.
#ifdef _WIN32
            fwrite(input.data, 1, (size_t)input.len, stdin_file);
#else
            // A write to a closed pipe must not kill the parent.
            sigset_t set;
            sigemptyset(&set);
            sigaddset(&set, SIGPIPE);
            pthread_sigmask(SIG_BLOCK, &set, NULL);
            fwrite(input.data, 1, (size_t)input.len, stdin_file);
#endif
            fclose(stdin_file);
        }
    }

    // The poll loop reads the output and keeps the clock.
#ifdef _WIN32
    int out_fd = -1;
#else
    int out_fd = fileno(child.stdout_file);
#endif
    int64_t start = proc_now_ms();
    int stopped = 0;
    char buffer[4096];
    for (;;) {
        unsigned got = subprocess_read_stdout(&child, buffer, sizeof buffer);
        if (got > 0) {
            gs_bld_append(out, (const uint8_t *)buffer, (int64_t)got);
            continue;
        }
        if (!subprocess_alive(&child)) {
            while ((got = subprocess_read_stdout(&child, buffer, sizeof buffer)) > 0) {
                gs_bld_append(out, (const uint8_t *)buffer, (int64_t)got);
            }
            break;
        }
        if (timeout_ms > 0 && proc_now_ms() - start >= timeout_ms) {
            subprocess_terminate(&child);
            stopped = 1;
            break;
        }
        proc_wait(out_fd);
    }

    int return_code = 0;
    subprocess_join(&child, &return_code);
    subprocess_destroy(&child);
    if (has_thread) {
        // The writer gives up when the child ends.
        writer.stop = 1;
#ifdef _WIN32
        WaitForSingleObject(thread, INFINITE);
        CloseHandle(thread);
#else
        pthread_join(thread, NULL);
#endif
    }
    proc_list_free(&env);

    *code = return_code;
    return stopped ? PROC_STOPPED : PROC_ENDED;
}
