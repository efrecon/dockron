# dockron

This is a service called `dockron.tcl` that is able to execute docker
commands on (groups of) components on a regular basis.  The actions to
perform are taken from the command-line option `-rules`, which should
be a white-space separated list of specifications, a multiple of 7
items.  The items are taken in turns and are interpreted as described
below:

1. The minute of the day.
2. The hour of the day.
3. The day of the month
4. The month number.
5. The day of the week.
6. A glob-style pattern to match against the names of the component
7. The command to execute, e.g. `restart`, `pause`, etc.

For all the date related specifications, the component controller
follows the `crontab` conventions, meaning that you should be able to
specify "any" using `*`, but also intervals such as `[0-5,14-18]`, or
"every 3" using `*/3*`.