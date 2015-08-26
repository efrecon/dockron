FROM efrecon/mini-tcl
MAINTAINER Emmanuel Frecon <emmanuel@sics.se>

# COPY code
COPY *.md /opt/dockron/
COPY dockron.tcl /opt/dockron/

# Ensure we have socat since nc on busybox does not support UNIX
# domain sockets.
RUN apk add --update-cache socat git && \
    git clone https://github.com/efrecon/docker-client /tmp/docker-client && \
    mv /tmp/docker-client/docker /opt/dockron/docker/ && \
    rm -rf /tmp/docker-client && \
    rm -rf /var/cache/apk/*

# Export where we will look for the Docker UNIX socket.
VOLUME ["/tmp/docker.sock"]

ENTRYPOINT ["tclsh8.6", "/opt/dockron/dockron.tcl", "-docker", "unix:///tmp/docker.sock"]
CMD ["-verbose", "4"]
