# =============================================================================
# Copilot Sandbox image
#
# Base: IBM Semeru Runtimes (Open) JDK 21 on Ubuntu Jammy.
# Adds: Node.js 22 (required by Copilot CLI), Maven, and the GitHub Copilot CLI.
# =============================================================================
FROM ibm-semeru-runtimes:open-21-jdk-jammy

# --- Versions (override at build time with --build-arg) -----------------------
ARG NODE_MAJOR=22
ARG MAVEN_VERSION=3.9.9

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
    && ln -s /opt/maven/bin/mvn /usr/local/bin/mvn
ENV MAVEN_HOME=/opt/maven

# --- GitHub Copilot CLI -------------------------------------------------------
RUN npm install -g @github/copilot

# --- Azure CLI ----------------------------------------------------------------
# Required by the Azure DevOps MCP server, which authenticates via `az login`.
# (This is also the documented extension point for adding other vendor CLIs.)
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash \
    && rm -rf /var/lib/apt/lists/*

# --- Non-root user ------------------------------------------------------------
RUN groupadd --gid "${APP_GID}" "${APP_USER}" \
    && useradd --uid "${APP_UID}" --gid "${APP_GID}" --create-home --shell /bin/bash "${APP_USER}"

# Maven settings: routes dependency resolution through the company Artifactory.
# Credentials/URL are resolved from env vars at runtime (see maven/settings.xml).
COPY --chown=${APP_UID}:${APP_GID} maven/settings.xml /home/${APP_USER}/.m2/settings.xml

# Copilot stores its credentials/config here; persisted via a Docker volume.
ENV COPILOT_HOME=/home/${APP_USER}/.copilot

# Azure CLI stores its login/credentials here; persisted via a Docker volume so
# the `az login` device flow only has to be done once.
ENV AZURE_CONFIG_DIR=/home/${APP_USER}/.azure

# Workspace where the agent checks out and works on code.
ENV WORKSPACE=/home/${APP_USER}/workspace
RUN mkdir -p "${COPILOT_HOME}" "${AZURE_CONFIG_DIR}" "${WORKSPACE}" \
    && chown -R "${APP_USER}:${APP_USER}" "/home/${APP_USER}"

# MCP server manifest + entrypoint that renders it into Copilot's mcp-config.json.
COPY mcp/servers.json /opt/copilot-sandbox/mcp/servers.json
COPY entrypoint.sh /opt/copilot-sandbox/entrypoint.sh
RUN chmod +x /opt/copilot-sandbox/entrypoint.sh

USER ${APP_USER}
WORKDIR ${WORKSPACE}

ENTRYPOINT ["/opt/copilot-sandbox/entrypoint.sh"]
CMD ["copilot"]
