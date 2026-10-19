# Building OpenZFS in a container

Build and test OpenZFS on the Linux distribution of your choice, without
installing build dependencies on your own machine.

The source tree is bind mounted into the container and each base image gets
its own out-of-tree build directory under `build/<image>`, so you can switch
distributions without rebuilding from scratch, and the same checkout can be
built by several distributions at once.

## Quick start

```sh
.docker/build.sh                    # ubuntu:24.04, the default
.docker/build.sh -i fedora          # fedora:latest
.docker/build.sh -i centos-stream9
.docker/build.sh -i alpine
```

Each of those builds userspace into its own directory:

```
build/ubuntu-24.04/
build/fedora-latest/
build/quay.io-centos-centos-stream9/
build/alpine-latest/
```

`--list` shows the short names that are known:

```sh
.docker/build.sh --list
```

Short names are only a convenience. Any image reference Docker understands
works, because dependency installation probes the package manager at image
build time rather than hardcoding a distribution:

```sh
.docker/build.sh -i debian:13
.docker/build.sh -i opensuse/tumbleweed:latest
.docker/build.sh -i registry.example.com/my-base:v3
```

`apt`, `dnf`/`yum`, `zypper`, `pacman` and `apk` are all handled. Package
names that don't exist on a given image are reported and skipped rather than
failing the build, since names drift between releases.

## Everyday use

The first argument after the options is a command for the container:

```sh
.docker/build.sh -i fedora                       # build (the default)
.docker/build.sh -i fedora configure             # re-run configure only
.docker/build.sh -i fedora make zfs              # make a single target
.docker/build.sh -i fedora make clean
.docker/build.sh -i fedora check                 # make check
.docker/build.sh -i fedora make unit             # userspace unit tests
.docker/build.sh -i fedora make checkstyle       # cstyle, shellcheck, ...
.docker/build.sh -i fedora shell                 # poke around
.docker/build.sh -i fedora distclean             # drop this build dir
```

Anything that isn't one of those verbs is run directly, so you can invoke a
binary you just built:

```sh
.docker/build.sh -i fedora ./build/fedora-latest/zdb -h
.docker/build.sh -i fedora ./build/fedora-latest/ztest -V
```

Useful options:

```sh
.docker/build.sh -i fedora -j 16                 # make -j16
.docker/build.sh -i ubuntu -i fedora42           # one tree, two distributions
.docker/build.sh -i ubuntu -e 'clang lld'        # extra packages in the image
.docker/build.sh -i ubuntu --configure-args '--enable-debug'
.docker/build.sh -i ubuntu --build-only          # just build the image
```

`ztest` needs no kernel module and is a good smoke test on any Docker host:

```sh
.docker/build.sh -i ubuntu ./build/ubuntu-24.04/ztest -V -T 60
```

## Userspace only, by default

The default configure line is `--with-config=user`: userspace libraries and
commands, no kernel modules.

That default exists because a container does not have its own kernel. Inside
the container `uname -r` reports the *host's* kernel, whose headers are not in
the image, so a module build would either fail or silently compile against the
wrong version. Commands like `zfs` and `zpool` build and run fine; they just
report that the modules aren't loaded if you try to use them.

The userspace build, `make check`, `make unit`, `ztest`, `make checkstyle`,
and `make lint` do not need a Linux kernel, so they run in these containers
on any Docker host. `checkstyle` is cstyle, shellcheck, mancheck,
commitcheck, and the other source checks. The image installs shellcheck,
checkbashisms, mandoc, cppcheck, flake8, and scanelf, which configure
notices when the build directory is created. `zstdcheck`, one part of `checkstyle`,
objdumps kernel zstd objects, so it only means something after a module
build.

Userspace-only is not enough for the ZFS Test Suite.

## Running the test suite

The test suite exercises a live filesystem, so it needs the kernel modules
loaded. That has real prerequisites:

- **A Linux host.** On macOS and Windows, Docker runs containers inside a
  hypervisor VM whose kernel headers aren't available, so you cannot build a
  module that matches the kernel the container runs on. `--kernel` refuses to
  run there rather than producing a module that won't load. Use a Linux
  machine, or drive a VM the way CI does — see
  `.github/workflows/scripts/qemu-*.sh`.
- **Kernel headers for the running kernel** on the host, at
  `/lib/modules/$(uname -r)/build`:

  ```sh
  apt-get install linux-headers-$(uname -r)      # Debian/Ubuntu
  dnf install kernel-devel-$(uname -r)           # Fedora/RHEL
  ```

- **A privileged container.** The suite needs loopback devices, device
  mapper, and `insmod`.

> **This loads modules into your host kernel.** There is no per-container
> module namespace: `--privileged` plus `insmod` modifies the running kernel
> for the whole machine, and the suite creates pools, loopback devices and
> test users that outlive the container. ZTS is also perfectly capable of
> panicking a kernel. Run it on a machine you are willing to lose — a VM or
> dedicated test box, not your workstation.

### Full suite

Build the modules, then load and test in one container. The module has to be
loaded in the same container that runs the tests, so chain the two commands in
a single shell:

```sh
# Build userspace + modules against the host kernel.
.docker/build.sh -i ubuntu --kernel

# Load the module stack and run the whole suite.
.docker/build.sh -i ubuntu --privileged shell -c \
    'zfs-build modules && zfs-build test -v'
```

`--kernel` implies `--privileged`, mounts the host's `/lib/modules` and
`/usr/src` read-only, and switches configure to `--with-config=all`.

That default is `common.run,linux.run` — 215 test groups, and hours of
wall clock. For a much shorter run, use `sanity`:

```sh
... 'zfs-build modules && zfs-build test -v -r sanity'
```

The runfiles in `tests/runfiles/` are `common`, `linux`, `sanity`, `bclone`,
`longevity` and `perf-regression` (plus `freebsd` and `sunos`, not applicable
here). Note that `zfs-tests.sh -h` advertises a `linux-fast` runfile that
does not exist in this tree; `sanity` is the short run.

Other options worth knowing, all passed straight through to
`scripts/zfs-tests.sh` (`zfs-build test -h` for the full list):

```
-v          verbose
-r FILE     runfile (default: common.run,linux.run -- the full suite)
-T TAGS     comma-separated tags, or a fraction like 1/3 to shard
-s SIZE     vdev size (default 4G; CI uses 3GB)
-x          remove leftover testpools, dm and loopback devices first
-k          don't clean up after a failure, so you can inspect it
-R          automatically rerun failures
-I NUM      iterations
```

### A single test, or a few

`-t` takes either a path relative to the test suite or a bare test name:

```sh
# By name
.docker/build.sh -i ubuntu --privileged shell -c \
    'zfs-build modules && zfs-build test -v -t zfs_bookmark_cliargs'

# By path
.docker/build.sh -i ubuntu --privileged shell -c \
    'zfs-build modules && zfs-build test -v -t tests/functional/cli_root/zfs_bookmark/zfs_bookmark_cliargs.ksh'
```

`-t` can be repeated to run several tests in one go, which reuses the one
module load and pool setup:

```sh
.docker/build.sh -i ubuntu --privileged shell -c \
    'zfs-build modules && zfs-build test -v \
        -t zfs_bookmark_cliargs \
        -t zpool_add_001_pos \
        -t zfs_receive_001_pos'
```

To run a whole functional area, point `-t` at its directory, or select by tag:

```sh
# Everything under one directory
... 'zfs-build modules && zfs-build test -v -t tests/functional/cli_root/zfs_bookmark'

# By tag
... 'zfs-build modules && zfs-build test -v -T zfs_bookmark,zpool_add'
```

If you're iterating on one test, load the modules once and stay in the
container instead of paying for a reload every time:

```sh
.docker/build.sh -i ubuntu --privileged shell
# then, inside:
zfs-build modules
zfs-build test -v -t zfs_bookmark_cliargs
zfs-build make zfs                              # rebuild after an edit
zfs-build test -v -t zfs_bookmark_cliargs
```

Results are written to `/var/tmp/test_results/` inside the container. Mount
somewhere if you want them to survive the container exiting.

## Troubleshooting

**`/zfs is already configured in tree`** — someone ran `./configure` directly
in the source tree, and autoconf won't configure out-of-tree while a top-level
`config.status` exists. Clean it:

```sh
make distclean                  # in the source tree, on the host
.docker/build.sh --distclean-src   # or from a container
```

**`no built module found under .../module`** — the build was userspace-only.
Rebuild with `--kernel` (Linux host only).

**`/dev/zfs is missing`** — the module stack isn't loaded in *this* container.
Run `zfs-build modules` first, in the same container as the tests.

**`this container cannot load kernel modules`** — missing `--privileged`.

**Leftover pools or loopback devices** from a killed run: `zfs-build test -x`
clears testpools, device mapper entries and loopback devices before starting.

## Files

| File | Purpose |
| --- | --- |
| `Dockerfile` | Takes `BASE_IMAGE`; otherwise distribution-agnostic |
| `install-deps.sh` | Detects the package manager and installs build deps |
| `entrypoint.sh` | Out-of-tree configure/build/test driver (`zfs-build`) |
| `build.sh` | Host-side wrapper: image resolution, mounts, flags |

`install-deps.sh` installs the CI guest dependency set: userland, test
suite, and kernel packages. Headers named for the running kernel are
included when the distro packages that kernel. `build.sh --kernel` still
mounts the host's headers, because a module only loads into the kernel it
was built for.
