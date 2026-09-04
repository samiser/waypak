/* emits a bwrap-loadable bpf seccomp filter on stdout: flatpak's baseline
 * (tty keystroke injection, tracing, kernel keyring, mount family), plus
 * optional denial of nested user namespaces with --deny-userns */
#define _GNU_SOURCE
#include <errno.h>
#include <sched.h>
#include <seccomp.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/personality.h>

int main(int argc, char **argv) {
  int deny_userns = argc > 1 && strcmp(argv[1], "--deny-userns") == 0;
  scmp_filter_ctx ctx = seccomp_init(SCMP_ACT_ALLOW);
  if (!ctx)
    return 1;

  int rc = 0;
  const int denied[] = {
      SCMP_SYS(syslog),        SCMP_SYS(uselib),
      SCMP_SYS(acct),          SCMP_SYS(quotactl),
      SCMP_SYS(add_key),       SCMP_SYS(keyctl),
      SCMP_SYS(request_key),   SCMP_SYS(move_pages),
      SCMP_SYS(mbind),         SCMP_SYS(get_mempolicy),
      SCMP_SYS(set_mempolicy), SCMP_SYS(migrate_pages),
      SCMP_SYS(ptrace),        SCMP_SYS(perf_event_open),
      SCMP_SYS(mount),         SCMP_SYS(umount2),
      SCMP_SYS(pivot_root),    SCMP_SYS(chroot),
  };
  for (size_t i = 0; i < sizeof(denied) / sizeof(*denied); i++)
    rc |= seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), denied[i], 0);

  /* keystroke injection into the controlling terminal; the mask also matches
   * high-bit variants (CVE-2019-10063) */
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
    /* clone3's flags live in a struct seccomp can't inspect; ENOSYS makes
     * libcs fall back to clone, which the rule above covers */
    rc |= seccomp_rule_add(ctx, SCMP_ACT_ERRNO(ENOSYS), SCMP_SYS(clone3), 0);
  }

  if (rc != 0)
    return 1;
  return seccomp_export_bpf(ctx, 1) != 0;
}
