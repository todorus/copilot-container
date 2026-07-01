# =============================================================================
# Copilot Sandbox image
#
# Base: Ubuntu Noble (24.04 LTS) — the JDK is NOT bundled by the base image.
# Adds: IBM Semeru (Open) JDK 21, Node.js 22 (required by Copilot CLI), Maven,
#       and the GitHub Copilot CLI.
# =============================================================================

# --- Base image registry (override to pull from a company registry/mirror) ----
# The base image is pulled from ${BASE_IMAGE_REGISTRY}/${BASE_IMAGE}. By default
# it comes from Docker Hub. To use an internal registry/mirror, override at build
# time, e.g.:
#   --build-arg BASE_IMAGE_REGISTRY=registry.corp.example.com
# (the copilot-sandbox wrapper passes these from .env automatically).
ARG BASE_IMAGE_REGISTRY=docker.io
ARG BASE_IMAGE=ubuntu:noble
FROM ${BASE_IMAGE_REGISTRY}/${BASE_IMAGE}

# --- Versions (override at build time with --build-arg) -----------------------
ARG NODE_MAJOR=22
ARG MAVEN_VERSION=3.9.9

# IBM Semeru (Open) JDK 21 — downloaded from the ibmruntimes GitHub releases at
# build time (like Node/Maven below). SEMERU_RELEASE is the release tag and
# SEMERU_PKG_VERSION is the version segment embedded in the asset filename.
ARG SEMERU_RELEASE=jdk-21.0.9+10_openj9-0.56.0
ARG SEMERU_PKG_VERSION=21.0.9_10_openj9-0.56.0

# Non-root user the agent runs as.
ARG APP_USER=copilot
ARG APP_UID=1000
ARG APP_GID=1000

# =============================================================================
# >>> MCP SERVERS CONFIG <<<
# To add/remove MCP servers, edit `mcp/servers.json` (the manifest copied below).
# Set "enabled": true on the servers you want; secrets/URLs are injected at runtime
# via ${ENV_VARS}. The manifest path is configurable here:
ARG MCP_SERVERS_MANIFEST=/opt/copilot-sandbox/mcp/servers.json
ENV MCP_SERVERS_MANIFEST=${MCP_SERVERS_MANIFEST}
# =============================================================================

ENV DEBIAN_FRONTEND=noninteractive

# --- Base OS packages ---------------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        gettext-base \
        unzip \
        less \
    && rm -rf /var/lib/apt/lists/*

# --- IBM Semeru (Open) JDK 21 -------------------------------------------------
# Downloaded from the ibmruntimes GitHub releases at build time (the base image
# no longer bundles a JDK). Arch is detected so the image builds on amd64/arm64.
# The tarball is verified against its published SHA-256 before extraction.
ENV JAVA_HOME=/opt/java/semeru
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64)  SEMERU_ARCH=x64 ;; \
        arm64)  SEMERU_ARCH=aarch64 ;; \
        ppc64el) SEMERU_ARCH=ppc64le ;; \
        s390x)  SEMERU_ARCH=s390x ;; \
        *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    asset="ibm-semeru-open-jdk_${SEMERU_ARCH}_linux_${SEMERU_PKG_VERSION}.tar.gz"; \
    base_url="https://github.com/ibmruntimes/semeru21-binaries/releases/download/${SEMERU_RELEASE}"; \
    curl -fsSL "${base_url}/${asset}" -o /tmp/semeru.tar.gz; \
    curl -fsSL "${base_url}/${asset}.sha256.txt" -o /tmp/semeru.sha256.txt; \
    echo "$(awk '{print $1}' /tmp/semeru.sha256.txt)  /tmp/semeru.tar.gz" | sha256sum -c -; \
    mkdir -p "${JAVA_HOME}"; \
    tar -xzf /tmp/semeru.tar.gz -C "${JAVA_HOME}" --strip-components=1; \
    rm -f /tmp/semeru.tar.gz /tmp/semeru.sha256.txt; \
    "${JAVA_HOME}/bin/java" -version
ENV PATH=${JAVA_HOME}/bin:${PATH}

# --- Node.js (via NodeSource) -------------------------------------------------
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- Maven (binary tarball, so it uses the Semeru JDK installed above) ---------
RUN curl -fsSL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
        -o /tmp/maven.tar.gz \
    && mkdir -p /opt/maven \
    && tar -xzf /tmp/maven.tar.gz -C /opt/maven --strip-components=1 \
    && rm /tmp/maven.tar.gz \
    && ln -s /opt/maven/bin/mvn /usr/local/bin/mvn.real
ENV MAVEN_HOME=/opt/maven

# Transparent `mvn` shim: routes through `jf mvn` (Artifactory, authenticated via
# the JFrog CLI credential store) when configured, else falls back to plain Maven.
COPY bin/mvn /usr/local/bin/mvn
RUN chmod +x /usr/local/bin/mvn

# --- GitHub Copilot CLI -------------------------------------------------------
RUN npm install -g @github/copilot

# --- Azure CLI ----------------------------------------------------------------
# Required by the Azure DevOps MCP server, which authenticates via `az login`.
# (This is also the documented extension point for adding other vendor CLIs.)
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash \
    && rm -rf /var/lib/apt/lists/*

# --- JFrog CLI ----------------------------------------------------------------
# Used for secure Artifactory authentication (browser/device `jf login`, or a
# scoped access token via stdin) so no plaintext credentials are ever placed in
# environment variables. Maven resolves through Artifactory via `jf mvn`.
RUN curl -fL https://install-cli.jfrog.io | sh \
    && jf --version

# --- Non-root user ------------------------------------------------------------
# ubuntu:noble ships a default `ubuntu` user at UID/GID 1000; remove it so the
# copilot user can take that id (the Jammy-based Semeru image had no such user).
RUN if getent passwd "${APP_UID}" >/dev/null; then userdel -r "$(getent passwd "${APP_UID}" | cut -d: -f1)" 2>/dev/null || true; fi \
    && if getent group "${APP_GID}" >/dev/null; then groupdel "$(getent group "${APP_GID}" | cut -d: -f1)" 2>/dev/null || true; fi \
    && groupadd --gid "${APP_GID}" "${APP_USER}" \
    && useradd --uid "${APP_UID}" --gid "${APP_GID}" --create-home --shell /bin/bash "${APP_USER}"

# Copilot stores its credentials/config here; persisted via a Docker volume.
ENV COPILOT_HOME=/home/${APP_USER}/.copilot

# Azure CLI stores its login/credentials here; persisted via a Docker volume so
# the `az login` device flow only has to be done once.
ENV AZURE_CONFIG_DIR=/home/${APP_USER}/.azure

# JFrog CLI stores its Artifactory credentials here; persisted via a Docker volume
# so the `jf login` web flow (or token config) only has to be done once.
ENV JFROG_CLI_HOME_DIR=/home/${APP_USER}/.jfrog

# Workspace where the agent checks out and works on code.
ENV WORKSPACE=/home/${APP_USER}/workspace
RUN mkdir -p "${COPILOT_HOME}" "${AZURE_CONFIG_DIR}" "${JFROG_CLI_HOME_DIR}" "${WORKSPACE}" \
    && chown -R "${APP_USER}:${APP_USER}" "/home/${APP_USER}"

# MCP server manifest + entrypoint that renders it into Copilot's mcp-config.json.
COPY mcp/servers.json /opt/copilot-sandbox/mcp/servers.json
COPY entrypoint.sh /opt/copilot-sandbox/entrypoint.sh
RUN chmod +x /opt/copilot-sandbox/entrypoint.sh

USER ${APP_USER}
WORKDIR ${WORKSPACE}

ENTRYPOINT ["/opt/copilot-sandbox/entrypoint.sh"]
CMD ["copilot"]
