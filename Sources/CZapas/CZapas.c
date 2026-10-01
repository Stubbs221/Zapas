#include "CZapas.h"
#include <errno.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#include <time.h>

int zp_read_system(zp_system *out) {
    memset(out, 0, sizeof(*out));
    size_t length = sizeof(out->physical_bytes);
    if (sysctlbyname("hw.memsize", &out->physical_bytes, &length, NULL, 0)) return -errno;
    vm_size_t page = 0;
    mach_port_t host = mach_host_self();
    kern_return_t result = host_page_size(host, &page);
    if (result != KERN_SUCCESS) { mach_port_deallocate(mach_task_self(), host); return -(int)result; }
    out->page_size = page;
    vm_statistics64_data_t vm = {0};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    result = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (result != KERN_SUCCESS) out->vm_error = result;
    else {
        out->wired_pages = vm.wire_count;
        out->compressed_pages = vm.compressor_page_count;
        out->active_pages = vm.active_count;
        out->inactive_pages = vm.inactive_count;
        out->free_pages = vm.free_count;
        out->swapins = vm.swapins;
        out->swapouts = vm.swapouts;
    }
    struct xsw_usage swap = {0};
    length = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &length, NULL, 0)) out->swap_error = errno;
    else { out->swap_used_bytes = swap.xsu_used; out->swap_total_bytes = swap.xsu_total; }
    struct timeval boot = {0};
    length = sizeof(boot);
    if (sysctlbyname("kern.boottime", &boot, &length, NULL, 0)) out->boot_error = errno;
    else { out->boot_seconds = boot.tv_sec; out->boot_microseconds = boot.tv_usec; }
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    out->awake_seconds = (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e9;
    return 0;
}

int zp_list_pids(int32_t *buffer, int capacity) {
    int size = buffer ? capacity * (int)sizeof(int32_t) : 0;
    int result = proc_listpids(PROC_ALL_PIDS, 0, buffer, size);
    return result > 0 ? result / (int)sizeof(int32_t) : -(errno ? errno : EIO);
}

int zp_read_process(int32_t pid, zp_process *out) {
    memset(out, 0, sizeof(*out));
    struct proc_bsdinfo before = {0}, after = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, sizeof(before)) != sizeof(before))
        return -(errno ? errno : ESRCH);
    out->pid = pid; out->ppid = before.pbi_ppid; out->uid = before.pbi_uid;
    out->start_seconds = before.pbi_start_tvsec; out->start_microseconds = before.pbi_start_tvusec;
    snprintf(out->name, sizeof(out->name), "%s", before.pbi_name[0] ? before.pbi_name : before.pbi_comm);
    proc_pidpath(pid, out->path, sizeof(out->path));
    struct rusage_info_v0 usage = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V0, (rusage_info_t *)&usage)) out->memory_error = errno ? errno : EACCES;
    else { out->footprint_bytes = usage.ri_phys_footprint; out->rss_bytes = usage.ri_resident_size; }
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) != sizeof(after))
        return -(errno ? errno : ESRCH);
    if (before.pbi_start_tvsec != after.pbi_start_tvsec || before.pbi_start_tvusec != after.pbi_start_tvusec
        || before.pbi_uid != after.pbi_uid) return -EAGAIN;
    return 0;
}

static int private_parent(const char *path) {
    char parent[PATH_MAX];
    if (!path || path[0] != '/' || strlen(path) >= sizeof(parent)) return EINVAL;
    strcpy(parent, path);
    char *slash = strrchr(parent, '/');
    if (!slash || slash == parent) return EACCES;
    *slash = 0;
    struct stat info;
    if (lstat(parent, &info)) return errno;
    if (!S_ISDIR(info.st_mode) || info.st_uid != getuid() || (info.st_mode & 077)) return EACCES;
    return 0;
}

static int address(const char *path, struct sockaddr_un *addr) {
    if (strlen(path) >= sizeof(addr->sun_path)) return ENAMETOOLONG;
    memset(addr, 0, sizeof(*addr));
    addr->sun_family = AF_UNIX; addr->sun_len = sizeof(*addr);
    strcpy(addr->sun_path, path);
    return private_parent(path);
}

static void configure(int fd) {
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    struct timeval timeout = {.tv_sec = 3};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
}

static int same_user(int fd) {
    uid_t uid; gid_t gid;
    return getpeereid(fd, &uid, &gid) == 0 && uid == getuid();
}

int zp_socket_listen(const char *path) {
    struct sockaddr_un addr;
    int error = address(path, &addr);
    if (error) return -error;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -errno;
    configure(fd);
    // Never replace an existing service, symlink or stale socket.
    int bound = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
    error = errno;
    if (bound) { close(fd); return -error; }
    if (chmod(path, 0600) || listen(fd, 16)) {
        error = errno; close(fd); unlink(path); return -error;
    }
    return fd;
}

int zp_socket_accept(int fd) {
    int client = accept(fd, NULL, NULL);
    if (client < 0) return -errno;
    configure(client);
    if (!same_user(client)) { close(client); return -EACCES; }
    return client;
}

int zp_socket_connect(const char *path) {
    struct sockaddr_un addr;
    int error = address(path, &addr);
    if (error) return -error;
    struct stat info;
    if (lstat(path, &info)) return -errno;
    if (!S_ISSOCK(info.st_mode) || info.st_uid != getuid() || (info.st_mode & 077)) return -EACCES;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -errno;
    configure(fd);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr))) { error = errno; close(fd); return -error; }
    if (!same_user(fd)) { close(fd); return -EACCES; }
    return fd;
}

int zp_wait_readable(int fd, int milliseconds) {
    struct pollfd item = {.fd = fd, .events = POLLIN};
    int result;
    do { result = poll(&item, 1, milliseconds); } while (result < 0 && errno == EINTR);
    if (result < 0) return -errno;
    return result;
}

int zp_read_exact(int fd, void *buffer, size_t count) {
    size_t offset = 0;
    struct timeval timeout = {0};
    socklen_t timeout_size = sizeof(timeout);
    int bounded = getsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, &timeout_size) == 0 && (timeout.tv_sec || timeout.tv_usec);
    struct timespec tick;
    clock_gettime(CLOCK_MONOTONIC, &tick);
    double deadline = tick.tv_sec + tick.tv_nsec / 1e9 + timeout.tv_sec + timeout.tv_usec / 1e6;
    while (offset < count) {
        // A slow-drip client must not extend the broker's read deadline forever.
        // Pipes (Chrome stdin) intentionally have no idle deadline.
        if (bounded) {
            clock_gettime(CLOCK_MONOTONIC, &tick);
            double remaining = deadline - tick.tv_sec - tick.tv_nsec / 1e9;
            if (remaining <= 0) return -ETIMEDOUT;
            int ready = zp_wait_readable(fd, (int)(remaining * 1000) + 1);
            if (ready <= 0) return ready < 0 ? ready : -ETIMEDOUT;
        }
        ssize_t result = read(fd, (char *)buffer + offset, count - offset);
        if (result < 0) { if (errno == EINTR) continue; return -errno; }
        if (!result) return offset ? -EPROTO : 0;
        offset += (size_t)result;
    }
    return 1;
}

int zp_write_exact(int fd, const void *buffer, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        ssize_t result = write(fd, (const char *)buffer + offset, count - offset);
        if (result < 0) { if (errno == EINTR) continue; return -errno; }
        if (!result) return -EIO;
        offset += (size_t)result;
    }
    return 0;
}
