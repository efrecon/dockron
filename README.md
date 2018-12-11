# dockron

Dockron is able to execute docker commands on (groups of) entities on a regular
basis, based on a cron-like syntax.  Example of such entities are containers,
but also, networks, (Swarm) nodes, secrets, etc. It relies on the Docker client
[implementation in Tcl][1] (See the end of this document for how to resolve
dependencies).

  [1]: <https://github.com/efrecon/tockler> "Engine API in Tcl"

The rationale for Dockron is to be able to move scheduling (as in time
scheduling, not container scheduling) into one or several central places.
Sometimes, you need to schedule tasks that are meaningful to your
application/stack, and expressing these as a Dockron service (in a compose file,
for example) is meaningful. Other scenarios are to regularily schedule various
operations on an entire Swarm.

## Usage

### Command-Line

Dockron is able to connect to the local Docker UNIX socket, but also remote
docker daemons.  The program takes a number of dash-led options and arguments.
Provided it is properly installed, running it as below should provide help for
its options.

    ./dockron.tcl -h

#### Rules

The actions to perform on entities are taken from the command-line option
`-rules`.  Its value should be a white-space separated list of specifications,
which needs to contain a multiple of 8 items.  The items are taken in turns and
are interpreted as described below:

1. The minute of the day (see below)
2. The hour of the day (see below)
3. The day of the month (see below)
4. The month number (see below)
5. The day of the week (see below)
6. The combination of an entity type and a glob-style pattern to match against
   the name(s) of the entity.  When the type is not explicitely specified, it
   will be considered to target containers.
7. The command to execute, e.g. `restart`, `pause`, as [available][1] from the
   API implementation.
8. Additional arguments to the command.

For all the date and time related specifications, the component controller
follows the `crontab` conventions, meaning that you should be able to specify
"any" using `*`, but also intervals such as `0-5,14-18,34`, or "every 3" using
`*/3`.  The command to execute can be empty, in which case the arguments are
used in a slightly different way as explained below.

#### Matching Types and Entities

When looking for matching entities, the specification (6th argument in the rule
list) should be composed of a type specification, followed by a slash `/`,
followed by a glob-style pattern. The type can be omitted, in which case the
slash can also be omitted. Empty patterns lead to slightly different behaviours
(see below).

The type specification is case insensitive and can be shortened to the minimum
descriptive string within the set of entities for brievity.  At present, Dockron
supports the following (mostly self explanatory) types of entities:

* `C` or any string beginning with `CONT` (as for example `CONTAINER`).
* `S` or any string beginning with `SER` (as for example `SERVICE`). This will
  match against the existing services among a manager of the swarm.
* Any string beginning with `V` (as for example `VOLUME`).
* Any string beginning with `I` (as for example `IMAGE`).
* `N` or any string beginning with `NO` (as for example `NODE`). This will
  match against the existing nodes known to a manager of the swarm.
* `W` or any string beginning with `NE` (as for example `NETWORK`).
* `R` or any string beginning with `SEC` (as for example `SECRET`). This will
  match against the existing secrets known to a manager of the swarm.
* `G` or any string beginning with `CONF` (as for example `CONFIG`). This will
  match against the existing configurations known to a manager of the swarm.

In general, the glob-style pattern will be matched against the name(s) of the
entities.  For containers, the leading slashes of the name will not be
considered.  For images, matching will happen against the tags.

#### Command Construction and Execution

##### Matching Entities

When constructing the API call to communicate with the Docker daemon, the
identifiers of all the entities matching the pattern will automatically be
appended to the command, followed by the arguments.  For example, a rule
specification expressed as follows will arrange for restarting all containers
matching the pattern `*myworker*`.

    12 */2 * * * C/*myworker* "container restart" ""

##### Empty Patterns for System Commands

An empty glob-style pattern (or the single dash `-`) is a special case that can
be used for system commands, or commands that do not operate on a specific
entity, e.g. `prune` commands. For example, a rule expressed as follows will
arrange to prune all stopped containers at a host.

    12 */2 * * * C/- "container prune" ""

##### Empty Commands for Complex Commands

An empty command is yet another special case, a case that can be used to express
more complex command sequences.  In that case, the remaining arguments are used
to form a Tcl command that will communicate with the Docker daemon once some
keywords have been substituted.  Keywords are surrounded by the percent `%`
sign, and the list of known keywords is the following:

* `%cx` (or `%docker%`, an alias) will automatically be replaced by the internal
  identifier of the Docker connection, as returned by calls to `docker connect`
  by the API implementation.
* `%id%` will be replaced by the identifier of the entity that matched the
  pattern.
* `%name%` will be replaced by the name of the entity that matched the pattern.

For example, a rule specification as below will, once again, but expressed
differently restart all containers matching the pattern `*myworker*`. Note the
use of the leading `%cx%`, and of `%id%` which will, once dynamically
substituted, lead to a valid call to the Tcl Docker API implementation.

    12 */2 * * * C/*myworker* "" "%cx% container restart %id%"

Note that the command formed as such is called directly in the context of the
executing procedure and there are no security guards, nor execution within a
safe interpreter.

Sometimes, [tockler][1] is not complete, alternatively makes it complex to
express what the regular `docker` CLI command makes easier to interface.  In
those cases, and as long as you remain on the same host, you should be able to
call the local `docker` binary (usually at `/usr/bin/docker`) using Tcl's [exec]
command. It is even possible to perform this kind of operation from within the
Docker container of [dockron][3], provided you mount the docker controlling
socket at `/var/run/docker.sock` and the binary itself at `/usr/bin/docker` into
the container. The Dockerfile adds a number of compability packages to the base
Alpine installation to make it possible to call the `docker` binary from Alpine,
even if the container runs on, e.g. Ubuntu, and the binary is mounted into the
container. This is possible because of the minimal dependencies that are present
in Go binaries.

  [exec]: https://www.tcl.tk/man/tcl/TclCmd/exec.htm

##### Using Templates

When the first character of the arguments is an arobas `@`, all characters after
the arobas form the path to a template file that will be read once. Its content
will be substituted each time necessary, as if it had come from the arguments
and is explained in the previous section. Offloading content to a file allows
for even more complex calls and/or construction, benefiting from the entire
expressiveness of the Tcl syntax.

For example, creating the following content in a file called `test.tcl` and
arranging for setting the 8th item of the rule list to `@./test.tcl` would
arrange to prune away all dangling images.  Note that the command makes a direct
call to `docker filters`, a helper procedure from the Docker Tcl implementation
meant to facilitate the construction of JSON expressions that should be sent as
part of the API query.

    %cx% image prune -filter [docker filters dangling 1]

Some operations are easier to execute using the regular `docker` command-line
client as opposed to through the API, e.g. scaling a service. For these
usecases, it is possible to use calls to Tcl `exec` to relay identifiers and or
names to the regular `docker` command-line client. For example, supposing that
`%name%` matches the name of an existing service, the following line in such a
template, would arrange to scale the matching service to 3 replicas:

    exec docker service scale %name%=3

If you want to run such operations when `dockron` is run as part of its Docker
[image][3] you will have to ensure that the `docker` executable is itself
accessible to the container, e.g. through mounting the executable from the host
into the container as a volume: `-v /usr/bin/docker:/usr/bin/docker`.

### Compose

To run Dockron from [compose][2], you would could specify something like the
following, which would automatically restart two sorts of worker components once
every two hours. Pay attention to the quotes around starting and ending the list
of `-rules`.

    watchdog:
      image: efrecon/dockron
      restart: always
      volumes:
        - /var/run/docker.sock:/var/run/docker.sock:ro
      command: >-
        -rules
          "12 */2 * * * *myworker* restart \"\"
           13 */2 * * * *myotherworker* restart \"\""
        -verbose INFO

  [2]: <https://docs.docker.com/compose/> "Compose Documentation"

## Installation and Dependencies

### Docker Container

Dockron is best run as a Docker container.  Get it from the [hub][3], where it
will always be available at its latest version, or build it yourself using:

    docker build -t efrecon/dockron .

  [3]: <https://hub.docker.com/r/efrecon/dockron/>

To run it locally, you will need to mount the docker socket into the component,
e.g. (but the following command wouldn't do much...):

    docker run -it --rm -v /var/run/docker.sock:/var/run/docker.sock efrecon/dockron -h

### Directly on the Host

`dockron` uses git [submodules], make sure to clone with recursion to arrange
for accessing the Docker API implementation.

  [submodules]: https://git-scm.com/book/en/v2/Git-Tools-Submodules