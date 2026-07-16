# ================================
# Build image
# ================================
FROM swift:6.1-jammy as build

# Set up a build area
WORKDIR /build

# First just resolve dependencies.
COPY ./Package.* ./
RUN swift package resolve

# Copy entire repo into container
COPY . .

# Build native static libraries (zero system dependency)
RUN ./script/build-native-libs.sh

# Build everything, with optimizations
RUN swift build -c release

# Switch to the staging area
WORKDIR /staging

# Copy main executable to staging area
RUN cp "$(swift build --package-path /build -c release --show-bin-path)/Run" ./

# Copy resources bundled by SPM to staging area
RUN find -L "$(swift build --package-path /build -c release --show-bin-path)/" -regex '.*\.resources$' -exec cp -Ra {} ./ \;

# Copy any resources from the public directory and views directory if the directories exist
RUN [ -d /build/Resources ] && { cp -Ra /build/Resources ./Resources && chmod -R a-w ./Resources; } || true

# ================================
# Run image
# ================================
FROM swift:6.1-jammy-slim

# Make sure all system packages are up to date, and install runtime deps.
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get -q install -y \
      ca-certificates \
      tzdata \
      ffmpeg \
      curl \
    && rm -r /var/lib/apt/lists/*

# Create a vapor user and group with /app as its home directory
RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor

# Switch to the new home directory
WORKDIR /app

# Copy built executable and any staged resources from builder
COPY --from=build --chown=vapor:vapor /staging /app

# Ensure all further commands run as the vapor user
USER vapor:vapor

# Let Docker bind to port 8080
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/api/stats || exit 1

# Start the Vapor service
ENTRYPOINT ["./Run"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
