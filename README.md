# dockron

Dockron is able to execute docker commands on (groups of) components
on a regular basis, based on a cron-like syntax.  It relies on the
Docker client [implementation in Tcl][1] (See this document for how to
resolve dependencies).

  [1]: <https://github.com/efrecon/docker-client> "Engine API in Tcl"

## Usage

### Command-Line

Dockron is able to connect to the local Docker UNIX socket, but also
remote docker daemons.  The program takes a number of dash-led options
and arguments, given its it is properly installed, running it as below
should provide help for its options.

    ./dockron.tcl -h

The actions to perform on components are taken from the command-line
option `-rules`.  Its value should be a white-space separated list of
specifications, which needs to contain a multiple of 7 items.  The
items are taken in turns and are interpreted as described below:

1. The minute of the day (see below)
2. The hour of the day (see below)
3. The day of the month (see below)
4. The month number (see below)
5. The day of the week (see below)
6. A glob-style pattern to match against the names of the component
7. The command to execute, e.g. `restart`, `pause`, as [available][1]

For all the date related specifications, the component controller
follows the `crontab` conventions, meaning that you should be able to
specify "any" using `*`, but also intervals such as `0-5,14-18,34`, or
"every 3" using `*/3*`.

### Composed

To run it from [compose][2], you would could specify something like
the following, which would automatically restart two sorts of worker
components once every two hours. Pay attention to the quotes around
starting and ending the list of `-rules`.

    watchdog:
      image: efrecon/dockron
      restart: always
      volumes:
        - /var/run/docker.sock:/tmp/docker.sock
      command: >-
        -rules
          "12 */2 * * * *myworker* restart
           13 */2 * * * *myotherworker* restart"
        -verbose INFO

  [2]: <https://docs.docker.com/compose/yml/> "Compose YAML Reference"

## Installation and Dependencies

### Docker Component

Dockron is best run as a docker component.  Get it from the [hub][3],
where it will always be available at its latest version, or build it
yourself using:

    docker build -t efrecon/dockron .

  [3]: <https://hub.docker.com/r/efrecon/dockron/>

To run it locally, you will need to mount the docker socket into the
component, e.g. (but the following command wouldn't do much...):

    docker run -it --rm -v /var/run/docker.sock:/tmp/docker.sock efrecon/dockron -h

### Manual

You need to ensure that dockron can access the `docker`
under-directory of the [engine Tcl implementation][1].  You can either
copy the content of the directory or arrange for a (symbolic) link.
Checkout for how the `Dockerfile` solves the dependency for an
example.