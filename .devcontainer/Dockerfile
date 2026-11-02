# Dev container for workstation-automation: authoring and linting only.
# Pinned tag: a floating "ubuntu" tag can move to a new release without notice.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Fail a RUN step if any command in a pipe fails (hadolint DL4006).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ShellCheck: the same linter CI enforces on every PR. Pinned upstream
# release, not Ubuntu's older package. Upstream publishes no checksum file;
# these hashes match GitHub's asset digests for the release. Bumping
# SHELLCHECK_VERSION means updating both hashes.
# TARGETARCH is set by BuildKit (amd64 on the host and in CI, arm64 on Apple
# silicon); dpkg is the fallback for builders that don't set it.
ARG SHELLCHECK_VERSION=0.11.0
ARG TARGETARCH
RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
    && case "${arch}" in \
         amd64) sc_arch=x86_64;  sc_sha256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 ;; \
         arm64) sc_arch=aarch64; sc_sha256=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588 ;; \
         *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;; \
       esac \
    && tarball="shellcheck-v${SHELLCHECK_VERSION}.linux.${sc_arch}.tar.xz" \
    && tmp="$(mktemp -d)" \
    && curl -fsSL -o "${tmp}/${tarball}" \
         "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/${tarball}" \
    && echo "${sc_sha256}  ${tmp}/${tarball}" | sha256sum -c - \
    && tar -xJf "${tmp}/${tarball}" -C "${tmp}" \
    && install -m 0755 "${tmp}/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck \
    && rm -rf "${tmp}"

# Pre-create ~/.claude owned by the non-root user. A new named volume
# mounted here copies this ownership; otherwise it would be root-owned.
RUN mkdir -p /home/vscode/.claude \
    && chown vscode:vscode /home/vscode/.claude

# Claude Code via Anthropic's native installer, run as the non-root user,
# so the binary in ~/.local is user-owned and its auto-updater can write.
# (The devcontainer Feature installs globally as root, which blocks updates.)
USER vscode
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/vscode/.local/bin:${PATH}"
