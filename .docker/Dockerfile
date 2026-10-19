# Build OpenZFS on the Linux distribution of your choice.
#
#   docker build -f .docker/Dockerfile --build-arg BASE_IMAGE=fedora:42 .docker
#
# The base image is the only thing that changes between distributions;
# install-deps.sh probes the package manager at run time, so any image with
# apt/dnf/yum/apk/pacman/zypper works.  Use .docker/build.sh for a wrapper
# that knows the common images by short name.
#
# See .docker/README.md for usage, including how to build kernel modules and
# run the ZFS Test Suite.

ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

# ARGs are cleared by FROM, so re-declare the ones we still need.
ARG BASE_IMAGE
ARG EXTRA_PACKAGES=""

LABEL org.openzfs.base-image="${BASE_IMAGE}"

COPY install-deps.sh /usr/local/bin/zfs-install-deps
RUN EXTRA_PACKAGES="${EXTRA_PACKAGES}" /usr/local/bin/zfs-install-deps

COPY entrypoint.sh /usr/local/bin/zfs-build

# Remembered so the entry point can give each base image its own build
# directory inside the bind-mounted source tree.
ENV ZFS_BASE_IMAGE="${BASE_IMAGE}" \
    ZFS_SRC=/zfs

WORKDIR /zfs
ENTRYPOINT ["/usr/local/bin/zfs-build"]
CMD ["build"]
