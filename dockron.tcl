#! /usr/bin/env tclsh

set dirname [file dirname [file normalize [info script]]]
set appname [file rootname [file tail [info script]]]
lappend auto_path [file join $dirname tockler]

package require docker 0.3;   # API implementation changes happened at this version
package require Tcl 8.5

set prg_args {
    -docker    "unix:///var/run/docker.sock" "UNIX socket for connection to docker"
    -rules     ""     "List of cron specifications for restarting (multiple of 8 when precision is minutes)"
    -verbose   INFO   "Verbose level"
    -reconnect 5      "Freq. of docker reconnection in sec., <0 to turn off"
    -precision "mins" "Precision first matching of seconds, minutes, hours, days."
    -h         ""     "Print this help and exit"
    -cert      ""     "Path to certificate when connecting to remote hosts with TLS"
    -key       ""     "Path to key when connecting to remote hosts with TLS"    
}

# Dump help based on the command-line option specification and exit.
proc ::help:dump { { hdr "" } {padding 12} } {
    global appname
    
    if { $hdr ne "" } {
        puts $hdr
        puts ""
    }
    puts "NAME:"
    puts "\t$appname - Docker (container, service, node, network, etc.) command scheduler"
    puts ""
    puts "USAGE"
    puts "\t${appname}.tcl \[options\]"
    puts ""
    puts "OPTIONS:"
    foreach { arg val dsc } $::prg_args {
        puts "\t[string range ${arg}[string repeat " " $padding] 0 $padding]$dsc (default: ${val})"
    }
    exit
}

# ::getopt -- Poor Man's getopt
#
#      Get options out of the list of (procedure or program) arguments.  Can
#      host the value and provide a default.
#
# Arguments:
#      _argv    Pointer to list of arguments to get value of option from
#      name     Name of the option to get from the list (often dash-led)
#      _var     Pointer to variable to set to value of option (or default)
#      default  Default for value of option when it does not exist.
#
# Results:
#      Return 1 when the option was found, 0 otherwise.
#
# Side Effects:
#      Actively modifies the incoming list of arguments to pict the options
#      from.
proc ::getopt {_argv name {_var ""} {default ""}} {
    upvar $_argv argv $_var var
    set pos [lsearch -regexp $argv ^$name]
    if {$pos>=0} {
        set to $pos
        if {$_var ne ""} {
            set var [lindex $argv [incr to]]
        }
        set argv [lreplace $argv $pos $to]
        return 1
    } else {
        # Did we provide a value to default?
        if {[llength [info level 0]] == 5} {set var $default}
        return 0
    }
}


# Did we ask for help at the command-line, print out all command-line
# options described above and exit.
if { [::getopt argv -h] } {
    ::help:dump
}

# Extract list of command-line options into array that will contain
# program state.  The description array contains help messages, we get
# rid of them on the way into the main program's status array.
array set DCKRN {
    docker     ""
}
foreach { arg val dsc } $prg_args {
    set DCKRN($arg) $val
}
for {set eaten ""} {$eaten ne $argv} {} {
    set eaten $argv
    foreach opt [array names DCKRN -*] {
        ::getopt argv $opt DCKRN($opt) $DCKRN($opt)
    }
}
array set TEMPLATES {}

# Remaining args? Dump help and exit
if { [llength $argv] > 0 } {
    ::help:dump "[lindex $argv 0] is an unknown command-line option!"
}

# Local constants and initial context variables.
docker verbosity $DCKRN(-verbose)

# Extra logging info with startup options.
set startup "Starting [file rootname [file tail [info script]]] with args\n"
foreach {k v} [array get DCKRN -*] {
    append startup "\t$k:\t$v\n"
}
docker log INFO [string trim $startup] $appname


# ::fieldMatch --
#
#	This command matches a crontab-like specification for a field
#	to a current value.
#
#	A field may be an asterisk (*), which always stands for
#	''first-last''.
#
#	Ranges of numbers are allowed.  Ranges are two numbers
#	separated with a hyphen.  The specified range is inclusive.
#	For example, 8-11 for an ''hours'' entry specifies execution
#	at hours 8, 9, 10 and 11.
#
#	Lists are allowed.  A list is a set of numbers (or ranges)
#	separated by commas.  Examples: ''1,2,5,9'', ''0-4,8-12''.
#
#	Step values can be used in conjunction with ranges.  Following
#	a range with ''/<number>'' specifies skips of the number's
#	value through the range.  For example, ''0-23/2'' can be used
#	in the hours field to specify command execution every other
#	hour (the alternative in the V7 standard is
#	''0,2,4,6,8,10,12,14,16,18,20,22'').  Steps are also permitted
#	after an asterisk, so if you want to say ''every two hours'',
#	just use ''*/2''.
#
# Arguments:
#	value	Current value of the field
#	spec	Matching specification
#
# Results:
#	returns 1 if the current value matches the specification, 0
#	otherwise
#
# Side Effects:
#	None.
proc ::fieldMatch { value spec } {
    if { $value != "0" } {
        regsub "^0" $value "" value
    }
    
    foreach rangeorval [split $spec ","] {
        
        # Analyse step specification
        set idx [string first "/" $rangeorval]
        if { $idx >= 0 } {
            set step [string trim \
                    [string range $rangeorval [expr $idx + 1] end]]
            set rangeorval [string trim \
                    [string range $rangeorval 0 [expr $idx - 1]]]
        } else {
            set step 1
            set rangeorval [string trim $rangeorval]
        }
        
        # Analyse range specification.
        set values ""
        set idx [string first "-" $rangeorval]
        if { $idx >= 0 } {
            set minval [string trim \
                    [string range $rangeorval 0 [expr $idx - 1]]]
            if { $minval != "0" } {
                regsub "^0" $minval "" minval
            }
            set maxval [string trim \
                    [string range $rangeorval [expr $idx + 1] end]]
            if { $maxval != "0" } {
                regsub "^0" $maxval "" maxval
            }
            for { set i $minval } { $i <= $maxval } { incr i $step } {
                if { $value == $i } {
                    return 1
                }
            }
        } else {
            if { $rangeorval == "*" } {
                if { ! [expr int(fmod($value, $step))] } {
                    return 1
                }
            } else {
                if { $rangeorval == $value } {
                    return 1
                }
            }
        }
    }
    
    return 0
}



# ::type -- Extract type (and pattern) from spec
#
#      Given a pattern formed of a set of characters separated from a glob-style
#      pattern by a slash (e.g. C/*), this will understands the various leading
#      strings into uppercase one letters, one for each type of objects that are
#      supported by the Docker interface. The incoming set of characters is case
#      insensitive and slash was chosen as a separator because it appears seldom
#      in the Docker namespace. This procedure is pardonning to ease human
#      entry: for example, it will accept any form of C or container or cont,
#      etc., using the minimal subset of characters necessary to identify the
#      object.
#
# Arguments:
#      spec     Specification in the form <type>/<ptn>
#      ptn_     Variable to host the pattern contained in the specification.
#
# Results:
#      Return one of C, S, V, I, N, W, R, G for (respectively) container,
#      service, volume, image, node, network, secret, config
#
# Side Effects:
#      None.
proc ::type {spec {ptn_ ""}} {
    # Arrange to be able to keep the pattern from the spec
    if { $ptn_ ne "" } {upvar $ptn_ ptn}

    # Detect types of objects to collect information on out of the patterns,
    # arrange for these types to be an uppercase single letter.
    set idx [string first "/" $spec]
    if { $idx >= 0 } {
        set type [string range $spec 0 [expr {$idx-1}]]
        set ptn [string range $spec [expr {$idx+1}] end]
        switch -glob -- [string toupper $type] {
            "" -
            "CONT*" -
            "C" {
                return "C"
            }
            "S" -
            "SER*" {
                return "S"
            }
            "V*" {
                return "V"
            }
            "I*" {
                return "I"
            }
            "N" -
            "NO*" {
                return "N"
            }
            "W" -
            "NE*" {
                return "W"
            }
            "SEC*" -
            "R" {
                return "R"
            }
            "CONF*" -
            "G" {
                return "G"
            }
        }
    }

    # Default type is a container for backward compatibility
    set ptn $spec
    return "C";
}


# ::connect -- (re)connect to the Docker daemon
#
#      Connect or reconnect to the Docker daemon using the URL specified at the
#      command-line.  Continuously keep trying when -reconnect is positive.
#
# Arguments:
#      None.
#
# Results:
#      None.
#
# Side Effects:
#      None.
proc ::connect {} {
    global DCKRN
    global appname
    
    if { $DCKRN(docker) ne "" } {
        catch {$DCKRN(docker) disconnect}
        set DCKRN(docker) ""
    }
    
    if { [catch {docker connect $DCKRN(-docker) -cert $DCKRN(-cert) -key $DCKRN(-key)} d] } {
        docker log WARN "Cannot connect to docker at $DCKRN(-docker): $d" $appname
    } else {
        docker log NOTICE "Connected to Docker daemon at $DCKRN(-docker)" $appname
        set DCKRN(docker) $d
    }
    
    if { $DCKRN(docker) eq "" } {
        if { $DCKRN(-reconnect) >= 0 } {
            set when [expr {int($DCKRN(-reconnect)*1000)}]
            after $when ::connect
        }
    } else {
        ::check
    }
}


# ::dget -- Dictionary get
#
#      Get the value of a key from a dictionary, if it exists, otherwise return
#      the default value.  Expells an error in the log whenever the message
#      isn't empty.
#
# Arguments:
#      dictionary dictionary value to get the key from
#      key        key to get the value for if it exists
#      err        Error to output if non-empty
#      dft        Default value when the key does not exist.
#
# Results:
#      Value of the key, or default value
#
# Side Effects:
#      None.
proc ::dget { dictionary key { err "" } { dft "" } } {
    global DCKRN
    global appname

    if { [dict exists $dictionary $key] } {
        return [dict get $dictionary $key]
    } elseif { $err ne "" } {
        docker log WARN $err
    }

    return $dft; #Failsafe default for all cases
}


# ::findInSpec -- Look for a name in the specifications from a list.
#
#      This procedure is tuned to find the name of nodes, secrets, etc. based on
#      the answers provided by the API when looking for these types of objects.
#      Given a list of objects, these objects are support to carry a sub-object
#      identified by a key named "Spec" by default. In that object, there should
#      be a name identified by default by "Name".  In those cases, and whenever
#      the pattern passed as a parameter this will return the list of all
#      identifiers and names from the list, where the identifiers are meant to
#      be found directly in the main list of objects at "ID" per-default.  When
#      the spec key is empty, the name is looked directly in the main objects of
#      the list instead (no sub-object), this suits constructs similar to the
#      ones returned when listing networks.
#
# Arguments:
#      ptn      Pattern to match against the names
#      lst      List of objects, as returned by the Docker API
#      what     Name of the thing we are looking for, for logging.
#      specKey  Name of the specification key, can be empty for no indirection
#      idKey    Name of the identifier key.
#
# Results:
#      Return an even-long list of identifiers and names matching the pattern.
#
# Side Effects:
#      None.
proc ::findInSpec { ptn lst what {specKey "Spec"} {idKey "ID"} } {
    global DCKRN
    global appname

    docker log DEBUG "Looking for ${what}s which names match $ptn" $appname
    set result {}
    foreach s $lst {
        # Find name key directly or under Spec
        set name ""
        if { $specKey eq "" } {
            set name [dget $spec Name "Cannot find name of ${what}!"]
        } else {
            set spec [dget $s $specKey "Cannot find specification for ${what}!"]
            if { $spec ne "" } {
                set name [dget $spec Name "Cannot find name of ${what} in specification!"]
            }
        }

        if { $name ne "" } {
            if { [string match $ptn $name] } {
                set id [dget $s $idKey "Cannot find identifier of ${what}!"]
                lappend result $id $name
                break
            }
        }
    }

    return $result
}


# ::find -- Find objects in API answers
#
#      Given a list of Docker objects (networks, containers, nodes, etc.) look
#      for the ones that match the pattern provided as an argument.  This
#      depends on the type of the object as the Docker API is not entirely
#      consistent.  In most cases, answers are more-or-less similarly formatted
#      and most work is then done by the findBySpec procedure.
#
# Arguments:
#      ptn      Pattern to match agains the names of the objects listed
#      type     Type of the object (one upper case letter, see type proc).
#      lst      List of objects, formatted as of the Docker API result
#
# Results:
#      Return an even-long list of identifiers and names matching the pattern.
#      Note that the identifier will be empty for volumes as they do not have
#      any identifier.
#
# Side Effects:
#      None.
proc ::find { ptn type lst } {
    global DCKRN
    global appname

    set result {}
    switch -- $type {
        "C" {
            docker log DEBUG "Looking for containers which names match $ptn" $appname
            foreach c $lst {
                set id [dget $c Id "Cannot find identifier in container specification!"]
                if { $id ne "" } {
                    set names [dget $c "Names" "Cannot find list of names in container specification!"]
                    if { [llength $names] } {
                        foreach name $names {
                            set name [string trimleft $name "/"]
                            if { [string match $ptn $name] } {
                                lappend result $id $name
                                break
                            }
                        }
                    }
                }
            }
        }
        "S" {
            set result [findInSpec $ptn $lst "service"]
        }
        "V" {
            docker log DEBUG "Looking for volumes which names match $ptn" $appname
            set volumes [dget $lst Volumes "Cannot find list of volumes!"]
            if { [llength $volumes] } {
                foreach v $volumes {
                    set name [dget $v Name "Cannot find name of volume!"]
                    if { $name ne "" } {
                        if { [string match $ptn $name] } {
                            lappend result "" $name;   # Volumes have no identifier
                            break
                        }
                    }
                }                        
            }
        }
        "I" {
            docker log DEBUG "Looking for images which names match $ptn" $appname
            foreach i $lst {
                set id [dget $i Id "Cannot find identifier of image"]
                if { [string first ":" $id] >= 0 } {
                    # Get rid of leading sha256: spec
                    lassign [split $id ":"] - id
                }
                set tags [dget $i RepoTags "Cannot find list of tags for image!"]
                foreach tag $tags {
                    if { [string match $ptn $tag] } {
                        lappend result $id $tag
                        break
                    }
                }
            }                        
        }
        "N" {
            set result [findInSpec $ptn $lst "node"]
        }
        "R" {
            set result [findInSpec $ptn $lst "secret"]
        }
        "G" {
            set result [findInSpec $ptn $lst "config"]
        }
        "W" {
            set result [findInSpec $ptn $lst "network" "" "Id"]
        }
    }

    return $result
}


# ::cmdexec -- Exec a docker sub-command
#
#      Execute a sub-command (of the Docker API implementation) followed by
#      arguments. When a command is provided, the identifier, it it exists,  is
#      automatically added after the command and before the arguments.  When no
#      command is provided, substitution of a number of known keys will occur
#      within the arguments, which are then supposed to form one or several
#      commands.  Known keys are %cx% (alias %docker%) for the identifier of the
#      docker connection, %id% for the identifier of the container, %name% for
#      the name of the container (both latest ones come from the arguments to
#      the procedure).
#
# Arguments:
#      cmd      Command to execute, empty for substitution from arguments instead
#      args     Arguments to command, or free-form command(s) to substitute from.
#      what     Type of the object to perform command on (for logging)
#      id       Identifier of the object, empty is ok.
#      name     Name of the object (empty is ok)
#
# Results:
#      None.
#
# Side Effects:
#      Operate on the Docker host, with great power comes great
#      responsabilities!!!
proc ::cmdexec { cmd args what { id "" } { name "" } { ptn "" } } {
    global DCKRN
    global appname
    global TEMPLATES

    if { $cmd eq "" } {
        set argv_backup $::argv;   # Store global arguments
        # When no command is provided, we use the new substitution-based API
        # that is able to form any kind of (sequential) commands, allowing for
        # more complex calls to the underlying API.
        set substitutions [list %cx% $DCKRN(docker) \
                                %docker% $DCKRN(docker) \
                                %id% $id \
                                %name% $name]
        # Get content of arguments from external file if it starts with an
        # arobas.
        if { [string index $args 0] eq "@" } {
            set fname [string range [lindex $args 0] 1 end]
            if { ![info exists TEMPLATES($fname)] } {
                if { [catch {open $fname} fd] == 0 } {
                    docker log INFO "Reading command template from $fname" $appname
                    set TEMPLATES($fname) [read $fd]
                    close $fd
                } else {
                    docker log ERROR "Cannot open template file at $fname: $fd" $appname
                }
            }
            if { [info exists TEMPLATES($fname)] } {
                # Pass remaining arguments, substituted as argv
                set ::argv [string map $substitutions [lrange $args 1 end]]
                docker log INFO "Passing substituted arguments to $fname: $::argv"
                set args [set TEMPLATES($fname)]
            }
        }

        set cmd [string map $substitutions $args]
        docker log NOTICE "Running '$cmd' on ${what} (matching $ptn)" $appname
        if { [catch $cmd val] == 0 } {
            if { [string trim $val] ne "" } {
                docker log INFO "Substituted command returned: $val" $appname
            }
        } else {
            docker log WARN "Substituted command returned an error: $val" $appname
        }
        set ::argv $argv_backup;   # Restore global arguments.
    } else {
        # Old-style interface assumes a command. The identifier of the matching
        # container and all arguments are blindly added to construct a command.
        if { $id eq "" && $name eq "" } {
            docker log NOTICE "Running '$cmd' on ${what}s with arguments: $args" $appname
            if { [catch {$DCKRN(docker) {*}$cmd {*}$args} val] == 0 } {
                if { [string trim $val] ne "" } {
                    docker log INFO "$cmd returned: $val" $appname
                }
            } else {
                docker log WARN "$cmd returned an error: $val" $appname
            }
        } else {
            # Pick the name in case we have no id (this will probably only occur
            # in the case of volumes).
            if { $id eq "" } {
                set id $name
            }
            docker log NOTICE "Running '$cmd' on $what $id (matching $ptn) with arguments: $args" $appname
            if { [catch {$DCKRN(docker) {*}$cmd $id {*}$args} val] == 0 } {
                if { [string trim $val] ne "" } {
                    docker log INFO "$cmd returned: $val" $appname
                }
            } else {
                docker log WARN "$cmd returned an error: $val" $appname
            }
        }
    }
}


# ::execute -- Execute a Docker sub-command on objects or all
#
#      Execute a docker API sub-command either on a subset of the objects that
#      match the pattern passed as an argument (the most usual case) or a
#      command that do not concern a particular object.
#
# Arguments:
#      ptn      Pattern to match against the name, empty or dash for no matching
#      type     One uppercase letter of the object type
#      cmd      Sub-command to execute (might be empty, see cmdexec)
#      args     Arguments to command, or free-form command(s) to substutute from
#      lst      List of object as returned by the various ls sub-commands of the API
#      what     Type of the object to perform command on (for logging)
#
# Results:
#      None.
#
# Side Effects:
#      Operate on the Docker host, with great power comes great
#      responsabilities!!!
proc ::execute { ptn type cmd args lst what } {
    global DCKRN
    global appname

    if { $ptn eq "" || $ptn eq "-" } {
        cmdexec $cmd $args $what
    } else {
        foreach {id name} [find $ptn $type $lst] {
            if { $id ne "" } {
        docker log INFO "calling back $id  $cmd $args" $appname
                cmdexec $cmd $args $what $id $name $ptn
            }
        }        
    }
}

proc ::rules { sec min hour daymonth month dayweek callback } {
    global DCKRN
    global appname    

    switch -nocase -glob -- $DCKRN(-precision) {
        "s*" {
            foreach {e_sec e_min e_hour e_daymonth e_month e_dayweek spec cmd args} $DCKRN(-rules) {
                if { [fieldMatch $sec $e_sec] \
                        && [fieldMatch $min $e_min] \
                        && [fieldMatch $hour $e_hour] \
                        && [fieldMatch $daymonth $e_daymonth] \
                        && [fieldMatch $month $e_month] \
                        && [fieldMatch $dayweek $e_dayweek] } {
                    set type [type $spec ptn]
                    {*}$callback $type $ptn $cmd {*}$args
                }
            }
        }
        "m*" {
            foreach {e_min e_hour e_daymonth e_month e_dayweek spec cmd args} $DCKRN(-rules) {
                if { [fieldMatch $min $e_min] \
                        && [fieldMatch $hour $e_hour] \
                        && [fieldMatch $daymonth $e_daymonth] \
                        && [fieldMatch $month $e_month] \
                        && [fieldMatch $dayweek $e_dayweek] } {
                    set type [type $spec ptn]
                    {*}$callback $type $ptn $cmd {*}$args
                }
            }
        }
        "h*" {
            foreach {e_hour e_daymonth e_month e_dayweek spec cmd args} $DCKRN(-rules) {
                if { [fieldMatch $hour $e_hour] \
                        && [fieldMatch $daymonth $e_daymonth] \
                        && [fieldMatch $month $e_month] \
                        && [fieldMatch $dayweek $e_dayweek] } {
                    set type [type $spec ptn]
                    {*}$callback $type $ptn $cmd {*}$args
                }
            }
        }
        "d*" {
            foreach {e_daymonth e_month e_dayweek spec cmd args} $DCKRN(-rules) {
                if { [fieldMatch $daymonth $e_daymonth] \
                        && [fieldMatch $month $e_month] \
                        && [fieldMatch $dayweek $e_dayweek] } {
                    set type [type $spec ptn]
                    {*}$callback $type $ptn $cmd {*}$args
                }
            }
        }
        default {
            docker log ERROR "$DCRN(-precision) is an unknown precision!" $appname
        }
    }
}

proc ::pick { containers services volumes images nodes secrets configs networks type ptn cmd args } {
    global DCKRN
    global appname
    
    switch -- $type {
        "C" {
            execute $ptn $type $cmd $args $containers "container"
        }
        "S" {
            execute $ptn $type $cmd $args $services "service"
        }
        "V" {
            execute $ptn $type $cmd $args $volumes "volume"
        }
        "I" {
            execute $ptn $type $cmd $args $images "image"
        }
        "N" {
            execute $ptn $type $cmd $args $nodes "node"
        }
        "R" {
            execute $ptn $type $cmd $args $secrets "secret"
        }
        "G" {
            execute $ptn $type $cmd $args $configs "config"
        }
        "W" {
            execute $ptn $type $cmd $args $networks "network"
        }
        default {
            docker log ERROR "$type is an unknown type!" $appname
        }
    }
} 

# ::check -- Timely check and execute command on matching objects
#
#      For all rules matching the current date and time, arrange to execute the
#      commands matching the object type and name pattern together with their
#      argument. Commands can be empty, types can be expressed in sloppy ways.
#      See execute and type procedures for more information (and the docs).
#      This is the core of the cron executioner, the implementation takes into
#      account the time to collect the objects relevant to the rules and to
#      execute the command for properly scheduling checks at regular intervals.
#
# Arguments:
#      None.
#
# Results:
#      None.
#
# Side Effects:
#      Might execute commands on containers, networks, etc. that match the
#      rules!
proc ::check {} {
    global DCKRN
    global appname
    
    # Remember exactly when we started all our different operations on Docker
    # objects.
    set start_ms [clock milliseconds]

    # Transform current date/time into the various fields that are relevant for
    # the cron-like date and time specification.
    set now [expr {$start_ms / 1000}]
    set sec [clock format $now -format "%S"];   # Really superfluous?
    set min [clock format $now -format "%M"]
    set hour [clock format $now -format "%H"]
    set daymonth [clock format $now -format "%e"]
    set month [clock format $now -format "%m"]
    set dayweek [clock format $now -format "%w"]
    
    # Arrange for the variable <types> to contain the list of one-uppercase
    # letter representation of Docker object types that should be considered by
    # the subset of the rules that are relevant right now.
    set types [list]
    rules $sec $min $hour $daymonth $month $dayweek {apply {{type ptn cmd args} {
        uplevel 2 lappend types $type
    }}}
    set types [lsort -unique $types]

    if { [llength $types] } {
        # Get current (relevant) list of containers, services, etc. This uses the
        # new sub-command based part of the API implementation.  The code
        # dynamically creates the variables that will hold relevant lists on the fly
        # and ensures that resources that are not necessary lead to an empty list.
        # This is done in a deterministic way so this exact set of dynamically
        # created variables will be used later on. The variables have names that
        # relates to the type of the object being listed, so we use the variable
        # names as part of the informational logging text.
        foreach {objtype cmd varname} {
            "C" "container ls -all 1" containers
            "S" "service ls" services
            "V" "volume ls" volumes
            "I" "image ls" images
            "N" "node ls" nodes
            "R" "secret ls" secrets
            "G" "config ls" configs
            "W" "network ls" networks
        } {
            set $varname [list];   # Failsafe
            foreach type $types {
                if { $objtype eq $type } {
                    docker log DEBUG "Collecting list of $varname" $appname
                    if { [catch {$DCKRN(docker) {*}$cmd} $varname] } {
                        docker log ERROR "Cannot list $varname!" $appname
                        if { $DCKRN(-reconnect) >= 0 } {
                            set when [expr {int($DCKRN(-reconnect)*1000)}]
                            after $when ::connect
                        }
                        # Fail early once we have lost the connection, there isn't
                        # anything that we will be able to do further on anyway.
                        # Reconnecting will automatically start checking for
                        # matching rules again by construction.
                        return
                    }
                }
            }
        }

        # Traverse all the rules and stop by all the ones that match the current
        # date and time.  Since we have collected the list of relevant Docker
        # objects earlier on, we can now execute the command and its arguments onto
        # the objects which name (and type) match the ones collected in the list, if
        # present. We also have ensured that all those variables exist, being empty
        # when not relevant.
        rules $sec $min $hour $daymonth $month $dayweek \
            [list ::pick $containers $services $volumes $images $nodes $secrets $configs $networks]
    }

    # Compute when to check for timers next time (taking care of time elapsed
    # since the very beginning of this procedure)
    switch -nocase -glob -- $DCKRN(-precision) {
        "s*" { set every 1 }
        "m*" { set every 60 }
        "h*" { set every 3600 }
        "d*" { set every 86400 }
        default { docker log ERROR "$DCKRN(-precision) is an unknown precision!" $appname }
    }
    set elapsed [expr {[clock milliseconds]-$start_ms}]
    set next [expr {(1000*$every)-$elapsed}]
    if { $next < 0 } {
        set next 0
    }
    docker log DEBUG "Entities collection and rule checking took $elapsed ms, next check in $next ms" $appname
    after $next ::check
}

connect;    # Will start checking
vwait forever
