#include <errno.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

static double seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + now.tv_nsec / 1e9;
}
static int read_usage(pid_t pid, struct rusage_info_v4 *usage) {
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)usage) == 0) return 1;
    perror("proc_pid_rusage");
    return 0;
}
int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) {
        fprintf(stderr, "Usage: %s PID|self [duration_seconds=15]\n", argv[0]);
        return 2;
    }
    char *end = NULL;
    long raw = strcmp(argv[1], "self") == 0 ? (long)getpid() : strtol(argv[1], &end, 10);
    if (raw <= 0 || (end && *end)) { fputs("Invalid PID\n", stderr); return 2; }
    double duration = argc == 3 ? strtod(argv[2], &end) : 15;
    if (duration <= 0 || duration > 300 || (argc == 3 && *end)) {
        fputs("Duration must be 0 < seconds <= 300\n", stderr); return 2;
    }
    pid_t pid = (pid_t)raw;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    // proc_pid_rusage CPU counters are Mach absolute ticks, including on Apple Silicon.
    const double tick_ms = (double)timebase.numer / timebase.denom / 1e6;
    struct rusage_info_v4 first, previous, current;
    if (!read_usage(pid, &first)) return 1;
    previous = first;
    double start = seconds(), last = start, now = start, max_cpu = 0;
    printf("pid=%d; CPU %% uses one core as 100%%; process only\n", pid);
    puts("elapsed_s,cpu_percent,user_ms,system_ms,idle_wakeups,interrupt_wakeups,footprint_MB,lifetime_peak_MB");
    while (now - start < duration) {
        double remaining = duration - (now - start), pause = remaining < 1 ? remaining : 1;
        struct timespec wait = { (time_t)pause, (long)((pause - (time_t)pause) * 1e9) };
        while (nanosleep(&wait, &wait) != 0 && errno == EINTR) {}
        if (!read_usage(pid, &current)) return 1;
        now = seconds();
        double user = (current.ri_user_time - previous.ri_user_time) * tick_ms;
        double system = (current.ri_system_time - previous.ri_system_time) * tick_ms;
        double cpu = (user + system) / ((now - last) * 10);
        if (cpu > max_cpu) max_cpu = cpu;
        printf("%.3f,%.5f,%.5f,%.5f,%llu,%llu,%.3f,%.3f\n", now - start, cpu, user, system,
               (unsigned long long)(current.ri_pkg_idle_wkups - previous.ri_pkg_idle_wkups),
               (unsigned long long)(current.ri_interrupt_wkups - previous.ri_interrupt_wkups),
               current.ri_phys_footprint / 1e6, current.ri_lifetime_max_phys_footprint / 1e6);
        fflush(stdout);
        previous = current; last = now;
    }
    double total_ms = ((current.ri_user_time - first.ri_user_time) +
                       (current.ri_system_time - first.ri_system_time)) * tick_ms;
    printf("TOTAL elapsed=%.3fs CPU=%.5f%% CPU_time=%.5fms max_interval=%.5f%% idle_wakeups=%llu interrupt_wakeups=%llu\n",
           now - start, total_ms / ((now - start) * 10), total_ms, max_cpu,
           (unsigned long long)(current.ri_pkg_idle_wkups - first.ri_pkg_idle_wkups),
           (unsigned long long)(current.ri_interrupt_wkups - first.ri_interrupt_wkups));
    return 0;
}
