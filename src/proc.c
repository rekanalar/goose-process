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
static void proc_poll_fd(int fd) {
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

// The pieces of a parsed spec.
struct proc_spec {
    const char *args[PROC_MAX_ARGS + 1];
    const char *cwd;
    struct proc_list env;
    const char *const *env_ptr;
    int options;
};

// Parse the flat buffer. combined selects the joined streams. It returns 0
// on a bad buffer. The caller frees the env of a parsed spec.
static int proc_parse(proc_slice spec, int combined, struct proc_spec *p) {
    const char *at = (const char *)spec.data;
    const char *end = at + spec.len;

    proc_list_init(&p->env);
    long argc = 0;
    at = proc_read_count(at, end, &argc);
    if (argc < 1 || argc > PROC_MAX_ARGS) return 0;
    for (long i = 0; i < argc; i++) {
        if (!proc_read_item(&at, end, &p->args[i])) return 0;
    }
    p->args[argc] = NULL;

    long envc = 0;
    at = proc_read_count(at, end, &envc);
    if (envc < 0 || envc > PROC_MAX_ENV) return 0;

    const char *entries[PROC_MAX_ENV];
    for (long i = 0; i < envc; i++) {
        if (!proc_read_item(&at, end, &entries[i])) return 0;
    }

    if (!proc_read_item(&at, end, &p->cwd)) return 0;

    p->options = subprocess_option_enable_async |
                 subprocess_option_enable_async_no_wait |
                 subprocess_option_search_user_path;
    if (combined) p->options |= subprocess_option_combined_stdout_stderr;

    // The child gets the environment of the parent, plus the entries that
    // the caller gave. Without an entry the child inherits the environment.
    p->env_ptr = NULL;
    if (envc > 0) {
        proc_load_parent_env(&p->env);
        for (long i = 0; i < envc; i++) {
            proc_env_set(&p->env, entries[i], strlen(entries[i]));
        }
#ifdef _WIN32
        // Windows wants the block sorted by name.
        qsort(p->env.items, (size_t)p->env.count, sizeof(char *), proc_env_cmp);
#endif
        p->env_ptr = (const char *const *)p->env.items;
    } else {
        p->options |= subprocess_option_inherit_environment;
    }
    return 1;
}

// A growable buffer of bytes that a slot holds for the caller.
struct proc_gbuf {
    uint8_t *data;
    int64_t len;
    int64_t cap;
};

static void proc_gbuf_free(struct proc_gbuf *buf) {
    free(buf->data);
    buf->data = NULL;
    buf->len = 0;
    buf->cap = 0;
}

static void proc_gbuf_append(struct proc_gbuf *buf, const char *data, int64_t len) {
    if (buf->len + len > buf->cap) {
        int64_t cap = buf->cap ? buf->cap : 4096;
        while (cap < buf->len + len) cap *= 2;
        uint8_t *grown = (uint8_t *)realloc(buf->data, (size_t)cap);
        if (!grown) return;
        buf->data = grown;
        buf->cap = cap;
    }
    memcpy(buf->data + buf->len, data, (size_t)len);
    buf->len += len;
}

// Start a program and wait for it. The flat buffer holds the arguments, the
// environment and the directory. It returns the status of the run and it
// fills the exit code.
int32_t proc_run(proc_slice spec, proc_slice input, gs_rref out, int32_t *code,
                 int32_t timeout_ms) {
    struct proc_spec parsed;
    if (!proc_parse(spec, 1, &parsed)) {
        proc_list_free(&parsed.env);
        return PROC_REFUSED;
    }

    struct subprocess_s child;
    const char *cwd_ptr = (parsed.cwd && parsed.cwd[0]) ? parsed.cwd : NULL;
    int created = subprocess_create_ex(parsed.args, parsed.options, parsed.env_ptr,
                                       cwd_ptr, &child);
    if (created != 0) {
        proc_list_free(&parsed.env);
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
        proc_poll_fd(out_fd);
    }

    int return_code = 0;
    subprocess_join(&child, &return_code);
    subprocess_destroy(&child);
    if (has_thread) {
        // The writer gives up when the child ends. A blocked write never
        // reads the flag, so the cancel breaks it.
        writer.stop = 1;
#ifdef _WIN32
        CancelSynchronousIo(thread);
        WaitForSingleObject(thread, INFINITE);
        CloseHandle(thread);
#else
        pthread_join(thread, NULL);
#endif
    }
    proc_list_free(&parsed.env);

    *code = return_code;
    return stopped ? PROC_STOPPED : PROC_ENDED;
}

// One slot of the handle table. It holds a live child.
struct proc_slot {
    int used;
    // The two streams stay apart.
    int apart;
    // The caller stopped the child.
    int killed;
    // The child was joined and destroyed.
    int reaped;
    // The exit code of a reaped child.
    int code;
    struct subprocess_s child;
    // NULL when the input is closed. The header closes the file when it
    // reaps the child, so this stays NULL after that.
    FILE *stdin_file;
    // The bytes of the output stream that the caller has not taken.
    struct proc_gbuf out;
    // The bytes of the error stream that the caller has not taken.
    struct proc_gbuf err;
};

// The table of the live children.
#define PROC_SLOTS 16
static struct proc_slot proc_table[PROC_SLOTS];

// The slot of an id. NULL for a bad id or a free slot.
static struct proc_slot *proc_slot(int32_t id) {
    if (id < 0 || id >= PROC_SLOTS) return NULL;
    if (!proc_table[id].used) return NULL;
    return &proc_table[id];
}

// The slot owns the file of the input. The header never closes it, so the
// file has one owner and one close.
static void proc_drop_in(struct proc_slot *slot) {
    if (!slot->stdin_file) return;
    fclose(slot->stdin_file);
    slot->stdin_file = NULL;
}

// The status of a child that the caller may have stopped.
static int proc_status(struct proc_slot *slot) {
    return slot->killed ? PROC_STOPPED : PROC_ENDED;
}

// The stop of a child stays a kill.
static void proc_stop(struct proc_slot *slot) {
    subprocess_terminate(&slot->child);
    slot->killed = 1;
}

// Wait for the child and destroy it. It gives the exit code. The file of
// the input closes first, so the child sees the end of its input.
static int proc_reap(struct proc_slot *slot) {
    proc_drop_in(slot);
    int return_code = 0;
    subprocess_join(&slot->child, &return_code);
    subprocess_destroy(&slot->child);
    slot->reaped = 1;
    slot->code = return_code;
    return return_code;
}

// A write to a closed pipe must not kill the parent.
static void proc_block_sigpipe(void) {
#ifndef _WIN32
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &set, NULL);
#endif
}

// Read the pipes of the child until they hold no more. It never blocks. The
// bytes wait in the slot until the caller reads them.
static void proc_drain(struct proc_slot *slot) {
    if (slot->reaped) return;
    char buffer[4096];
    unsigned got;
    while ((got = subprocess_read_stdout(&slot->child, buffer, sizeof buffer)) > 0) {
        proc_gbuf_append(&slot->out, buffer, (int64_t)got);
    }
    if (slot->apart) {
        while ((got = subprocess_read_stderr(&slot->child, buffer, sizeof buffer)) > 0) {
            proc_gbuf_append(&slot->err, buffer, (int64_t)got);
        }
    }
}

// Start a child without waiting for it. It returns the number of the slot
// of the child, or a number below zero. The status goes into *status.
int32_t proc_spawn(proc_slice spec, int32_t separate, int32_t *status) {
    struct proc_spec parsed;
    if (!proc_parse(spec, separate ? 0 : 1, &parsed)) {
        proc_list_free(&parsed.env);
        *status = PROC_REFUSED;
        return -1;
    }

    struct proc_slot *slot = NULL;
    int32_t id = -1;
    for (int32_t i = 0; i < PROC_SLOTS; i++) {
        if (!proc_table[i].used) {
            slot = &proc_table[i];
            id = i;
            break;
        }
    }
    if (!slot) {
        proc_list_free(&parsed.env);
        *status = PROC_REFUSED;
        return -1;
    }

    struct subprocess_s child;
    const char *cwd_ptr = (parsed.cwd && parsed.cwd[0]) ? parsed.cwd : NULL;
    if (0 != subprocess_create_ex(parsed.args, parsed.options, parsed.env_ptr,
                                  cwd_ptr, &child)) {
        proc_list_free(&parsed.env);
        *status = PROC_NOT_STARTED;
        return -1;
    }
    proc_list_free(&parsed.env);

    // The slot owns the file of the input. The header must not close it.
    memset(slot, 0, sizeof *slot);
    slot->used = 1;
    slot->apart = separate ? 1 : 0;
    slot->child = child;
    slot->stdin_file = subprocess_stdin(&child);
    slot->child.stdin_file = SUBPROCESS_NULL;
#ifndef _WIN32
    if (slot->stdin_file) {
        // The write of the caller never waits in the kernel buffer.
        int fd = fileno(slot->stdin_file);
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }
#endif
    *status = PROC_ENDED;
    return id;
}

// Say whether the child of the slot still lives. The check comes first, so
// the drain of the last call holds every byte of a child that just ended.
int32_t proc_alive(int32_t id) {
    struct proc_slot *slot = proc_slot(id);
    if (!slot) return -1;
    if (slot->reaped) return 0;
    int alive = subprocess_alive(&slot->child) ? 1 : 0;
    proc_drain(slot);
    return alive;
}

// Move the bytes that arrived since the last read into the buffers of the
// caller. It returns the count of the moved bytes, or -1 for a bad id.
int32_t proc_read(int32_t id, gs_rref out, gs_rref err) {
    struct proc_slot *slot = proc_slot(id);
    if (!slot) return -1;
    proc_drain(slot);
    int64_t total = slot->out.len + slot->err.len;
    if (slot->out.len > 0) gs_bld_append(out, slot->out.data, slot->out.len);
    if (slot->err.len > 0) gs_bld_append(err, slot->err.data, slot->err.len);
    // The slot keeps its memory for the next drain. The free releases it.
    slot->out.len = 0;
    slot->err.len = 0;
    if (total > 0x7fffffff) return -1;
    return (int32_t)total;
}

// Give bytes to the input of the child. The write runs in the thread of the
// caller and it waits while the child does not take them. It returns the
// count of the taken bytes, or -1 when the child is gone. A limit above 0
// ends the wait. The count of the taken bytes is then below the length.
int32_t proc_write(int32_t id, proc_slice bytes, int32_t timeout_ms) {
    struct proc_slot *slot = proc_slot(id);
    if (!slot) return -1;
    if (slot->reaped || !slot->stdin_file) return -1;
    if (bytes.len == 0) return 0;
    proc_drain(slot);
    int64_t done = 0;
    int64_t begin = proc_now_ms();
#ifdef _WIN32
    while (done < bytes.len) {
        size_t chunk = (size_t)(bytes.len - done);
        if (chunk > 4096) chunk = 4096;
        size_t wrote = fwrite(bytes.data + done, 1, chunk, slot->stdin_file);
        done += (int64_t)wrote;
        if (wrote == 0) {
            if (!subprocess_alive(&slot->child)) {
                proc_drop_in(slot);
                return -1;
            }
            if (timeout_ms > 0 && proc_now_ms() - begin >= timeout_ms) break;
            Sleep(1);
        }
    }
#else
    proc_block_sigpipe();
    int fd = fileno(slot->stdin_file);
    while (done < bytes.len) {
        ssize_t wrote = write(fd, bytes.data + done, (size_t)(bytes.len - done));
        if (wrote > 0) {
            done += (int64_t)wrote;
            continue;
        }
        if (wrote < 0 && errno != EAGAIN && errno != EWOULDBLOCK) break;
        // The child does not take the bytes yet. The drain keeps its output
        // pipe empty, so the child never waits on the parent.
        proc_drain(slot);
        if (!subprocess_alive(&slot->child)) {
            proc_drop_in(slot);
            return -1;
        }
        if (timeout_ms > 0 && proc_now_ms() - begin >= timeout_ms) break;
        struct pollfd entry;
        entry.fd = fd;
        entry.events = POLLOUT;
        entry.revents = 0;
        poll(&entry, 1, 1);
    }
    if (done == 0 && !subprocess_alive(&slot->child)) {
        proc_drop_in(slot);
        return -1;
    }
#endif
    if (done > 0x7fffffff) return -1;
    return (int32_t)done;
}

// Close the input of the child. The child then sees the end of its input.
int32_t proc_close_in(int32_t id) {
    struct proc_slot *slot = proc_slot(id);
    if (!slot) return -1;
    proc_drop_in(slot);
    return 0;
}

// Wait for the child. A limit of 0 waits without a limit. A child that does
// not end before the limit is stopped. The exit code goes into *code.
int32_t proc_wait(int32_t id, int32_t *code, int32_t timeout_ms) {
    struct proc_slot *slot = proc_slot(id);
    if (!slot) return PROC_REFUSED;
    if (slot->reaped) {
        *code = slot->code;
        return proc_status(slot);
    }
#ifdef _WIN32
    int out_fd = -1;
#else
    int out_fd = fileno(slot->child.stdout_file);
#endif
    int64_t start = proc_now_ms();
    for (;;) {
        proc_drain(slot);
        if (!subprocess_alive(&slot->child)) break;
        if (timeout_ms > 0 && !slot->killed && proc_now_ms() - start >= timeout_ms) {
            proc_stop(slot);
        }
        proc_poll_fd(out_fd);
    }
    // The child ended. One more drain holds the last bytes.
    proc_drain(slot);
    *code = proc_reap(slot);
    return proc_status(slot);
}

// Stop the child. The stop stays a kill, so a child that ignores the stop
// signal still dies.
int32_t proc_kill(int32_t id) {
    struct proc_slot *slot = proc_slot(id);
    if (!slot) return PROC_REFUSED;
    if (slot->reaped) return proc_status(slot);
    if (subprocess_alive(&slot->child)) {
        proc_stop(slot);
    }
    return proc_status(slot);
}

// Free the handle. A live child is stopped first, and the join waits for
// it. No resource of the child survives the free.
int32_t proc_free(int32_t id) {
    struct proc_slot *slot = proc_slot(id);
    if (!slot) return PROC_REFUSED;
    if (!slot->reaped) {
        if (subprocess_alive(&slot->child)) {
            proc_stop(slot);
        }
        proc_reap(slot);
    }
    proc_gbuf_free(&slot->out);
    proc_gbuf_free(&slot->err);
    int status = proc_status(slot);
    slot->used = 0;
    return status;
}
