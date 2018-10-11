FROM efrecon/mini-tcl:3.7
MAINTAINER Emmanuel Frecon <emmanuel@sics.se>

# Ensure we have socat since nc on busybox does not support UNIX
# domain sockets.
RUN apk add --no-cache socat libc6-compat libltdl

# COPY code
COPY *.md /opt/dockron/
COPY dockron.tcl /opt/dockron/
COPY tockler/*.tcl /opt/dockron/tockler/

# Export where we will look for the Docker UNIX socket.
VOLUME ["/tmp/docker.sock"]

ENTRYPOINT ["tclsh8.6", "/opt/dockron/dockron.tcl", "-docker", "unix:///tmp/docker.sock"]
CMD ["-verbose", "4"]
