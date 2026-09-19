# vboxsf-fix — endless write loop / data corruption in the Linux vboxsf driver

Writing to a **VirtualBox shared folder** from pages that have not been faulted in yet
makes the in-kernel `vboxsf` driver loop forever: the target file keeps growing with
zeroed data until the disk is full, the writing process cannot be interrupted, and the
kernel log fills up with `iov_iter_revert` warnings.

This repository contains a two-line fix, a DKMS package that keeps the patched module
in place across kernel updates, and a guard that prevents your shared folders from
being mounted when the patched module is *not* in use.

Status: **reported upstream**, awaiting review (see [Upstream status](#upstream-status)). Last updated: 2026-09-20.

Japanese write-up: https://techhowto.blog/posts/virtualbox-vboxsf-endless-write-loop-bug ([summary in this repo](README.ja.md))

## Do I have this bug?

You are probably hitting it if, inside a Linux VirtualBox guest:

* a file on a shared folder (`vboxsf`) **grows without limit** although the writer only
  asked for a few bytes, and the content is all zeroes;
* the writing process never returns and only dies on `SIGKILL`;
* `dmesg` repeats a warning such as

  ```
  WARNING: lib/iov_iter.c:624 at iov_iter_revert+0x1fc/0x270, CPU#3: vring_worker/3339
  ```

* `/var/log/syslog`, `/var/log/kern.log` and the journal grow by gigabytes.

Quick check:

```sh
findmnt -t vboxsf                 # do you use shared folders?
modinfo -n vboxsf                 # kernel/fs/vboxsf/... = in-tree (affected)
dmesg | grep -c iov_iter_revert
```

Typical triggers are programs that write **straight from an mmap of another file or
from shared memory** without reading it first — `virtiofsd` does exactly that, so
nested virtualisation on top of a shared folder hits it immediately. Ordinary
applications write from buffers they have just filled and are not affected.

## Affected versions

| | |
|---|---|
| Driver | in-kernel `fs/vboxsf` (the module shipped by your distribution kernel) |
| Confirmed on | Ubuntu 26.04.1, kernel 7.0.0-31-generic, VirtualBox 7.2.16 host |
| Source | the faulty code is identical in Linux v7.0 and in `master` as of 2026-09 |
| Not tested | the out-of-tree `vboxsf` shipped with Oracle's Guest Additions (different implementation) |
| Impact | confined to the guest: full disk, stuck process, log flood; possible silent data corruption (see below) |

## Root cause

`vboxsf_write_end()` ignores `copied`, the number of bytes the generic write path
actually managed to copy into the folio:

```c
	u32 nwritten = len;          /* initialised with the *requested* length */
	...
	if (!folio_test_uptodate(folio) && copied < len)
		folio_zero_range(folio, from + copied, len - copied);

	buf = kmap(&folio->page);
	err = vboxsf_write(sf_handle->root, sf_handle->handle,
			   pos, &nwritten, buf + from);   /* writes len bytes */
	...
	return nwritten;             /* reports len even when copied == 0 */
```

With `copied == 0` and `status == len`, `generic_perform_write()`:

1. calls `iov_iter_revert(i, copied - status)` with a negative value → `WARN_ON` fires;
2. skips `fault_in_iov_iter_readable()` because `status != 0`;
3. advances `pos` by `status` although the iterator was not advanced;
4. loops again — the source pages are still not faulted in, so this never ends.

A short copy is a normal condition, not an error: the kernel is expected to fault the
source pages in and retry, which is exactly what the `write_end` contract asks for
("A short copy made ->write_end() reject the thing entirely").

**Silent data corruption:** when the folio is already uptodate the stale range is not
zeroed, so a short copy makes vboxsf send the *old* folio contents to the host and
report a full write. Not observed in practice, but it follows from the same code.

## The fix

[`patches/0001-vboxsf-fix-endless-write-loop-on-short-copy.patch`](patches/0001-vboxsf-fix-endless-write-loop-on-short-copy.patch)

```diff
-	u32 nwritten = len;
+	u32 nwritten = copied;
 	...
+	/* Nothing copied: reject so generic_perform_write() faults in and retries */
+	if (!copied)
+		goto out;
+
 	buf = kmap(&folio->page);
```

Verified with the patched module: writes from non-faulted pages, partially copied
writes and in-place rewrites all produce byte-identical files on the host, and
`virtiofsd`-backed workloads (creating text and PNG files, copying, appending,
rewriting) complete with zero kernel warnings.

## Install

Requirements: `dkms`, `gcc`, `make`, `curl`, `patch` and the kernel headers for the
running kernel. Secure Boot must be off (the module is not signed).

```sh
git clone https://github.com/kentaro-shiomi/virtualbox-vboxsf-endless-write-loop-fix
cd virtualbox-vboxsf-endless-write-loop-fix
sudo ./scripts/install.sh          # or: sudo ./scripts/install.sh v7.0
```

The script downloads `fs/vboxsf` from `torvalds/linux` at the tag matching your kernel,
applies the patch, and registers it with DKMS so it is rebuilt automatically when the
kernel is updated. Reboot afterwards (or unmount the shared folders, `rmmod vboxsf`,
and mount again).

Check:

```sh
dkms status vboxsf-fix/1.0
modinfo -n vboxsf                 # .../updates/dkms/vboxsf.ko*
```

Uninstall:

```sh
sudo ./scripts/uninstall.sh
```

The installer downloads `fs/vboxsf` from raw.githubusercontent.com and falls back to
git.kernel.org; both are retried a few times, because anonymous downloads can be rate
limited (HTTP 429). If it still fails, wait a few minutes and run it again.

### Kernel version compatibility

The DKMS sources are the upstream `fs/vboxsf` files of one tag. The
`write_begin`/`write_end` prototypes changed in July 2025 (`struct kiocb *` argument),
so pass a tag that matches your kernel — the default derives it from `uname -r`.
The fix itself applies to older versions as well, but the patch context may differ.

### Guard: do not mount unless the patched driver is in use

If a DKMS build ever fails after a kernel update, the unpatched in-tree module is
loaded again — and the next write may run away unnoticed. `scripts/install.sh`
installs `vboxsf-fix-check` and a oneshot unit for this. Hook it into your mount unit:

```sh
sudo mkdir -p /etc/systemd/system/<your>.mount.d
sudo cp tools/mount-guard.conf.example /etc/systemd/system/<your>.mount.d/fix-check.conf
sudo systemctl daemon-reload
```

See `tools/mount-guard.conf.example`. Making the (empty) mount point immutable with
`chattr +i` additionally prevents writes from silently landing in the guest file system
while the share is not mounted.

## Workarounds without patching

* **Fault the source pages in before writing** (read the mmap/shared memory once).
  Only possible if you control the writer.
* **Do not use shared folders** for this workload — use SMB/SFTP/NFS instead. Note
  that `vboxsf` also has a long-standing `sendfile` issue that Vagrant documents.

## Upstream status

* Linux kernel (`fs/vboxsf` maintainer, linux-fsdevel, linux-kernel): patch sent on
  2026-09-19, awaiting review:
  https://lore.kernel.org/linux-fsdevel/20260919174136.3325-1-k.shiomi@techhowto.blog/
* Ubuntu (Launchpad): https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2167772
* A second, unrelated bug found during the investigation: opening a file on `vboxsf`
  with `O_DIRECT` fails as expected, but the cleanup dereferences a NULL pointer
  (`vboxsf_release_sf_handle` ← `vboxsf_file_release` ← `__fput` ← `openat`). Not
  covered by this patch.

## Reproducer

A minimal reproducer (a few lines of Python) exists but is not published here yet, to
avoid handing out a ready-made way to fill up other people's disks before the fix is
available from distributions. The trigger conditions are described in the submission
linked above. If you need the reproducer for verification, open an issue.

## License

The patch and the DKMS packaging follow the license of the file they modify:
`fs/vboxsf/file.c` is `SPDX-License-Identifier: MIT`. Everything in this repository is
published under the MIT license — see `LICENSE`.

## Credits

Found while running Claude Desktop (Linux beta) with Cowork inside a VirtualBox guest:
Cowork runs its tasks in a nested QEMU/KVM VM and exposes the working directory through
`virtiofsd`, which writes from shared memory — the exact trigger for this bug. A 6-byte
text file grew to 29 KB in seconds, and a PNG to 202 MB before the VM was killed.
