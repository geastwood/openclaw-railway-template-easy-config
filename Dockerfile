# Build openclaw from source to avoid npm packaging gaps (some dist files are not shipped).
FROM node:22-bookworm AS openclaw-build

# Dependencies needed for openclaw build
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*

# Install Bun (openclaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw

# Pin to a known ref (tag/branch). If it doesn't exist, fall back to main.
ARG OPENCLAW_GIT_REF=main
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements for packages that may reference unpublished versions.
# Apply to all extension package.json files to handle workspace protocol (workspace:*).
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build


# Runtime image
FROM node:22-bookworm
ENV NODE_ENV=production

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    build-essential \
    gcc \
    g++ \
    make \
    procps \
    file \
    git \
    python3 \
    python3-venv \
    python3-pip \
    pkg-config \
    sudo \
  && rm -rf /var/lib/apt/lists/*

# Install uv for skills that use inline Python script dependencies (for example nano-banana-pro).
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
  && mv /root/.local/bin/uv /usr/local/bin/uv \
  && if [ -f /root/.local/bin/uvx ]; then mv /root/.local/bin/uvx /usr/local/bin/uvx; fi

# Install goplaces CLI and keep the real binary at /usr/local/bin/goplaces-real.
RUN set -eux; \
  arch="$(dpkg --print-architecture)"; \
  case "${arch}" in \
    amd64) asset_regex='(linux_amd64|Linux_x86_64)\.tar\.gz$' ;; \
    arm64) asset_regex='(linux_arm64|Linux_arm64)\.tar\.gz$' ;; \
    *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;; \
  esac; \
  release_json="$(curl -fsSL https://api.github.com/repos/steipete/goplaces/releases/latest)"; \
  asset_url="$(printf '%s\n' "${release_json}" \
    | grep -Eo 'https://github.com/[^"]+/releases/download/[^"]+' \
    | grep -E "${asset_regex}" \
    | head -n1 || true)"; \
  if [ -z "${asset_url}" ]; then \
    echo "Could not find a matching goplaces release asset for ${arch}" >&2; \
    exit 1; \
  fi; \
  curl -fsSL "${asset_url}" \
    | tar -xz -C /usr/local/bin goplaces; \
  mv /usr/local/bin/goplaces /usr/local/bin/goplaces-real; \
  chmod +x /usr/local/bin/goplaces-real

# Install Homebrew (must run as non-root user)
# Create a user for Homebrew installation, install it, then make it accessible to all users
RUN useradd -m -s /bin/bash linuxbrew \
  && echo 'linuxbrew ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

USER linuxbrew
RUN NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

USER root
RUN chown -R root:root /home/linuxbrew/.linuxbrew
ENV PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:${PATH}"

WORKDIR /app

# Wrapper deps
RUN corepack enable
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --prod --frozen-lockfile && pnpm store prune

# Install Python PDF libraries for pdf skill using virtual environment approach
# Create a virtual environment to respect PEP 668 (externally managed Python)
RUN python3 -m venv /opt/pdf-venv

# Install PDF libraries in the virtual environment
RUN /opt/pdf-venv/bin/pip install --no-cache-dir pypdf pdfplumber reportlab && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    poppler-utils && \
    rm -rf /var/lib/apt/lists/*

# Add venv binaries to PATH for skill usage
ENV PATH="/opt/pdf-venv/bin:${PATH}"

# Install Chromium for Puppeteer (patient-health-portal-helper skill)
# Use specific version to ensure compatibility
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    fonts-ipafont-gothic \
    fonts-wqy-zenhei \
    fonts-thai-tlwg \
    fonts-kacst \
    fonts-freefont-ttf \
    libxss1 \
    && rm -rf /var/lib/apt/lists/* \
  && wget -q -O - https://dl-ssl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/googlechrome-linux-keyring.gpg \
  && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/googlechrome-linux-keyring.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list \
  && apt-get update \
  && apt-get install -y google-chrome-stable \
  && rm -rf /var/lib/apt/lists/*

# Copy all skills first (for dependency installation)
COPY skills /tmp/skills

# Install patient-health-portal-helper skill dependencies
# Note: package.json is in the lib/ subdirectory (ES modules structure)
WORKDIR /tmp/skills/patient-health-portal-helper/lib
RUN npm install && npm cache clean --force

# Return to app directory
WORKDIR /app

# Copy built openclaw
COPY --from=openclaw-build /openclaw /openclaw

# Provide a openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

COPY src ./src

# Wrap goplaces so successful invocations emit ClawClaw usage events.
RUN install -m 0755 src/bin/goplaces-wrapper.sh /usr/local/bin/goplaces

# Copy ClawHub skills (with installed dependencies)
RUN mkdir -p /data/.openclaw && cp -r /tmp/skills /data/.openclaw/skills && rm -rf /tmp/skills

ENV PORT=8080
EXPOSE 8080
CMD ["node", "src/server.js"]
