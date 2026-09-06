#define _GNU_SOURCE
#include <errno.h>
#include <sched.h>
#include <seccomp.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/personality.h>

int main(int argc, char **argv) {
  scmp_filter_ctx ctx = seccomp_init(SCMP_ACT_ALLOW);
  if (!ctx)
    return 1;

  int rc = 0;
  int deny_userns = 0;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--deny-userns") == 0) {
      deny_userns = 1;
      continue;
    }
    int nr = seccomp_syscall_resolve_name(argv[i]);
    if (nr == __NR_SCMP_ERROR) {
      fprintf(stderr, "unknown syscall: %s\n", argv[i]);
      return 1;
    }
    rc |= seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), nr, 0);
  }

  /* keystroke injection into the controlling terminal, masked so
   * high-bit variants match too (CVE-2019-10063) */
  rc |= seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(ioctl), 1,
                         SCMP_A1(SCMP_CMP_MASKED_EQ, 0xFFFFFFFFu,
                                 (unsigned int)TIOCSTI));
  rc |= seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(ioctl), 1,
                         SCMP_A1(SCMP_CMP_MASKED_EQ, 0xFFFFFFFFu,
                                 (unsigned int)TIOCLINUX));

  rc |= seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(personality), 1,
                         SCMP_A0(SCMP_CMP_NE, PER_LINUX));

  if (deny_userns) {
    rc |= seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(clone), 1,
                           SCMP_A0(SCMP_CMP_MASKED_EQ, CLONE_NEWUSER,
                                   CLONE_NEWUSER));
    rc |= seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(unshare), 1,
                           SCMP_A0(SCMP_CMP_MASKED_EQ, CLONE_NEWUSER,
                                   CLONE_NEWUSER));
    rc |= seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(setns), 0);
    /* clone3's flags live in a struct seccomp can't inspect, so ENOSYS
     * makes libcs fall back to clone, which the rule above covers */
    rc |= seccomp_rule_add(ctx, SCMP_ACT_ERRNO(ENOSYS), SCMP_SYS(clone3), 0);
  }

  if (rc != 0)
    return 1;
  return seccomp_export_bpf(ctx, 1) != 0;
}
