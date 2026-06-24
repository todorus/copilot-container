# =============================================================================
# Copilot Sandbox image
#
# Base: Ubuntu 24.04 (noble). The IBM Semeru (Open) JDK 21 is installed from the
# official release tarball (see the "Java" section below) rather than coming from
# a Semeru base image, because the Semeru image is not always mirrored internally
# while a plain Ubuntu image usually is.
# Adds: Semeru JDK 21, Node.js 22 (required by Copilot CLI), Maven, and the
# GitHub Copilot CLI.
# =============================================================================

# --- Base image registry (override to pull from a company registry/mirror) ----
# The base image is pulled from ${BASE_IMAGE_REGISTRY}/${BASE_IMAGE}. By default
# it comes from Docker Hub. To use an internal registry/mirror, override at build
# time, e.g.:
#   --build-arg BASE_IMAGE_REGISTRY=registry.corp.example.com
# (the copilot-sandbox wrapper passes these from .env automatically).
ARG BASE_IMAGE_REGISTRY=docker.io
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE_REGISTRY}/${BASE_IMAGE}

# --- Versions (override at build time with --build-arg) -----------------------
ARG NODE_MAJOR=22
ARG MAVEN_VERSION=3.9.9

# IBM Semeru (Open) JDK 21. Pinned for reproducible builds; override at build time.
# SEMERU_JDK_VERSION   : the release tag suffix (the part after "jdk-"), e.g.
#                        "21.0.9+10_openj9-0.56.0".
# SEMERU_JDK_FILE_VERSION: the same version as it appears in the asset filename,
#                        where "+" becomes "_" and the leading "jdk-" is dropped,
#                        e.g. "21.0.9_10_openj9-0.56.0".
# SEMERU_BASE_URL      : download host/path; override to point at an internal mirror.
ARG SEMERU_JDK_VERSION=21.0.9+10_openj9-0.56.0
ARG SEMERU_JDK_FILE_VERSION=21.0.9_10_openj9-0.56.0
ARG SEMERU_BASE_URL=https://github.com/ibmruntimes/semeru21-binaries/releases/download

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

# --- Java: IBM Semeru (Open) JDK 21 (tarball) ---------------------------------
# Installed from the official release tarball instead of a Semeru base image, so
# the image can be built on top of a (commonly mirrored) plain Ubuntu base.
# The architecture is detected at build time so the image builds on both x86_64
# and arm64 hosts. The tarball is checksum-verified against its published SHA-256.
ENV JAVA_HOME=/opt/java/semeru
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64)  SEMERU_ARCH=x64 ;; \
        arm64)  SEMERU_ARCH=aarch64 ;; \
        ppc64el) SEMERU_ARCH=ppc64le ;; \
        s390x)  SEMERU_ARCH=s390x ;; \
        *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    tarball="ibm-semeru-open-jdk_${SEMERU_ARCH}_linux_${SEMERU_JDK_FILE_VERSION}.tar.gz"; \
    url="${SEMERU_BASE_URL}/jdk-${SEMERU_JDK_VERSION}/${tarball}"; \
    curl -fsSL "$url" -o /tmp/semeru.tar.gz; \
    curl -fsSL "${url}.sha256.txt" -o /tmp/semeru.sha256; \
    echo "$(cut -d' ' -f1 /tmp/semeru.sha256)  /tmp/semeru.tar.gz" | sha256sum -c -; \
    mkdir -p "${JAVA_HOME}"; \
    tar -xzf /tmp/semeru.tar.gz -C "${JAVA_HOME}" --strip-components=1; \
    rm -f /tmp/semeru.tar.gz /tmp/semeru.sha256; \
    "${JAVA_HOME}/bin/java" -version
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# --- Node.js (via NodeSource) -------------------------------------------------
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- Maven (binary tarball, to avoid pulling a second JDK via apt) -------------
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
# Ubuntu 24.04 ships a default "ubuntu" user/group at UID/GID 1000; remove any
# pre-existing account occupying the target UID/GID before creating ours.
RUN if getent passwd "${APP_UID}" >/dev/null; then \
        userdel --remove "$(getent passwd "${APP_UID}" | cut -d: -f1)" 2>/dev/null || true; \
    fi \
    && if getent group "${APP_GID}" >/dev/null; then \
        groupdel "$(getent group "${APP_GID}" | cut -d: -f1)" 2>/dev/null || true; \
    fi \
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
