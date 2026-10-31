# Dev container for workstation-automation: authoring and linting only.
# Pinned tag: a floating "ubuntu" tag can move to a new release without notice.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Fail a RUN step if any command in a pipe fails (hadolint DL4006).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ShellCheck: the same linter CI enforces on every PR.
RUN apt-get update \
    && apt-get install -y --no-install-recommends shellcheck \
    && rm -rf /var/lib/apt/lists/*

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
