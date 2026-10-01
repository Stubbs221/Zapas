#ifndef CZAPAS_H
#define CZAPAS_H
#include <stdint.h>
#include <stddef.h>

typedef struct {
    uint64_t physical_bytes, page_size;
    uint64_t wired_pages, compressed_pages, active_pages, inactive_pages, free_pages;
    uint64_t swapins, swapouts, swap_used_bytes, swap_total_bytes;
    int64_t boot_seconds, boot_microseconds;
    double awake_seconds;
    int vm_error, swap_error, boot_error;
} zp_system;

typedef struct {
    int32_t pid, ppid;
    uint32_t uid;
    uint64_t start_seconds, start_microseconds, footprint_bytes, rss_bytes;
    int memory_error;
    char name[256];
    char path[4096];
} zp_process;

int zp_read_system(zp_system *out);
int zp_list_pids(int32_t *buffer, int capacity);
int zp_read_process(int32_t pid, zp_process *out);
int zp_socket_listen(const char *path);
int zp_socket_accept(int fd);
int zp_socket_connect(const char *path);
int zp_wait_readable(int fd, int milliseconds);
int zp_read_exact(int fd, void *buffer, size_t count);
int zp_write_exact(int fd, const void *buffer, size_t count);
#endif
