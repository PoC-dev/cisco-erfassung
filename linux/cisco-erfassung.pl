#!/usr/bin/perl -w

# This is to be manually incremented on each "publish".
my $versionstring = '2025-05-01.00';

# ----------------------------------------------------------------------------------------------------------------------------------

use strict;
no strict "subs"; # For allowing symbolic names for syslog priorities.
use warnings;
use DBI;
use Expect; # https://metacpan.org/pod/release/RGIERSIG/Expect-1.15/Expect.pod
use Date::Format;
use DateTime::Format::Strptime;
use File::Temp qw/ tempdir /;
use Getopt::Std;
use Sys::Syslog;

# We use syslog in the following way:
# LOG_ERR for when we die();
# LOG_WARNING for when we skip a host
# LOG_NOTICE for when we skip a sub-function of a host, or CVS/git function (which are a global but host-specific sub-function)
# LOG_INFO for regular messages for exceptions
# LOG_DEBUG for context in what we're doing currently

# ----------------------------------------------------------------------------------------------------------------------------------

# How to access the database
our $config;
require "/etc/cisco-config-backuprc"; # For safety reasons, this data is not in the script.
my $odbc_dsn    = $config->{'odbc_dsn'};
my $odbc_user   = $config->{'odbc_user'};
my $odbc_pass   = $config->{'odbc_pass'};

# Which source control managemnt tool to use.
my $cvsproject = $config->{'cvsproject'};
my $giturl = $config->{'giturl'};

# ----------------------------------------------------------------------------------------------------------------------------------

# General vars.
my ($asa_serno, $cfsavd_flash, $cleanup, $cnh, $dbh, $dirfh, $do_orphans, $do_scm, $do_scm_add, $do_setnull, $errcount, $fh, $file,
    $flash_size, $found__cfgsavd_in_running_cfg, $found__no_config_chance_since_restart, $hostname, $hostport, $inv_have_line_name,
    $inv_have_line_pid, $loopcount, $num_entries, $param, $quiet_mode, $retval, $scmdestfile, $scmtmp, $setnull_field,
    $show_config_command, $showverfeature, $sth_select_hosts, $test_db, $time_dtf, $tmpline, $to_clean_pf, $try_loop_string,
    $use_git, @beforeLinesArray, @cnh_parms, @errtyp, @filelist, @lines, @params, @setnull_fields, @show_config, @show_version,
    @time_tm, @to_clean_pfs, @try_loop_strings
);

# Matches a Cisco-CLI-Prompt, so Expect knows when the result of the sent command has been sent.
my $prompt_re = '^((?!<).)*[\#>]\s?$';

# Vars from hstpf.
my ($hostnameport, $conn_method, $username, $passwd, $enable, $wartungstyp);

# Vars from cfgverpf.
my ($lineno, $line);

# Vars from dcapf. Also see handler if $do_setnull == 1!
my ( $asa_dm_ver, $asa_fover, $cfsavd, $cfupdt, $confreg, $flash, $just_reloaded, $model, $ram, $reload_reason, $romver, $serno,
    $stamp, $sysimg, $uptime, $uptime_min, $version, $vtp_domain, $vtp_mode, $vtp_prune, $vtp_vers
);

# Vars from invpf.
my ($inv_name, $inv_descr, $inv_pid, $inv_vid, $inv_serno);

# Vars from acdcapf.
my ($ac_type, $ac_ver);

# Vars from vlanpf.
my ($vlan_descr, $vlan_no);

# For Expect.pm.
my ($pat, $err, $match, $before, $after);

# ----------------------------------------------------------------------------------------------------------------------------------

# See: https://alvinalexander.com/perl/perl-getopts-command-line-options-flags-in-perl/

my %options = ();
$retval = getopts("cdhnoqtv", \%options);

if ( $retval != 1 ) {
    printf(STDERR "Wrong parameter error. Wanna use git and forgot to give an URL?\n\n");
}

if ( defined($options{h}) || $retval != 1 ) {
    printf("Version %s\n", $versionstring);
    printf("Usage: cisco-erfassung(.pl) [options] device1 [device2 ...]\nOptions:
    -c: Suppress CVS/git functions
    -d: Enable debug mode: much more logging and to stderr
    -h: Show this help and exit
    -n: Suppress setting empty database fields to NULL
    -o: Suppress cleanup of orphaned database entries and CVS/git files
    -q: Be quiet about connection errors
    -t: Test database connection and exit
    -v: Show version and exit\n\n");
    printf("Note that logging is done almost entirely via syslog, facility user.\n");
    exit(0);
} elsif ( defined($options{v}) ) {
    printf("Version %s\n", $versionstring);
    exit(0);
}


# Enable debug mode.
if ( defined($options{d}) ) {
    $cleanup = 0;
    openlog("cisco-erfassung", "perror,pid", "user");
} else {
    $cleanup = 1;
    openlog("cisco-erfassung", "pid", "user");
    # Omit debug messages by default.
    # FIXME: What is the correct way to handle this with symbolic names?
    setlogmask(127);
}
# Test database connection and exit.
if ( defined($options{t}) ) {
    $test_db = 1;
} else {
    $test_db = 0;
}
# Be quiet about connection errors.
if ( defined($options{q}) ) {
    $quiet_mode = 1;
} else {
    $quiet_mode = 0;
}
# Suppress CVS/git functions.
if ( defined($options{c}) ) {
    $do_scm = 0;
} else {
    $do_scm = 1;
}
# Suppress setting empty database fields to NULL.
if ( defined($options{n}) ) {
    $do_setnull = 0;
} else {
    $do_setnull = 1;
}
# Suppress cleanup of orphaned database entries, and orphaned CVS/git files.
if ( defined($options{o}) ) {
    $do_orphans = 0;
} else {
    $do_orphans = 1;
}

# ----------------------------------------------------------------------------------------------------------------------------------

# Now let the game begin!
if ( $test_db == 1 ) {
    printf("Connecting to database...\n");
} else {
    syslog(LOG_INFO, "Startup: our version is '%s'", $versionstring);
}
syslog(LOG_DEBUG, "Init: connecting to database");
$dbh = DBI->connect($odbc_dsn, $odbc_user, $odbc_pass, {PrintError => 0, LongTruncOk => 1});
if ( ! defined($dbh) ) {
    if ( $test_db == 1 ) {
        printf(STDERR "Connection to database failed: %s\n", $dbh->errstr);
    }
    syslog(LOG_ERR, "Init: connection to database failed: %s", $dbh->errstr);
    die;
} elsif ( defined($dbh) && $test_db == 1 ) {
    printf("Database connection established successfully.\n");
    exit(0);
}


# Use git or CVS?
if ( $do_scm == 1 ) {
    if ( defined($giturl) && ! defined($cvsproject) ) {
        $use_git = 1;
        syslog(LOG_DEBUG, "SCM: using git with URL '%s'", $giturl);
    } elsif ( ! defined($giturl) && defined($cvsproject) ) {
        $use_git = 0;
        syslog(LOG_DEBUG, "SCM: using cvs with project '%s'", $cvsproject);
    } else {
        syslog(LOG_ERR, "SCM: both cvsproject and giturl found in configuration, this is invalid");
        die;
    }
}

# ------------------------------------------------------------------------------

# Prepare reusable SQL statements.
syslog(LOG_DEBUG, "Init: preparing reusable SQL statements");
my $sth_delete_invpf = $dbh->prepare("DELETE FROM invpf WHERE hostname=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error: %s", $dbh->errstr);
    die;
}
my $sth_insert_invpf = $dbh->prepare("INSERT INTO invpf (hostname, inv\$name, inv\$descr, inv\$pid, inv\$vid, inv\$serno) \
    VALUES (?, ?, ?, ?, ?, ?)");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error: %s", $dbh->errstr);
    die;
}

my $sth_delete_dcapf = $dbh->prepare("DELETE FROM dcapf WHERE hostname=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error: %s", $dbh->errstr);
    die;
}
my $sth_insert_dcapf = $dbh->prepare("INSERT INTO dcapf (confreg, flash, hostname, model, ram, romver, serno, stamp, sysimg, \
    uptime, uptime_min, version, asa_dm_ver, rld\$reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error: %s", $dbh->errstr);
    die;
}
my $sth_update_dcapf_cfsavd = $dbh->prepare("UPDATE dcapf SET cfsavd=? WHERE hostname=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error: %s", $dbh->errstr);
    die;
}
my $sth_update_dcapf_cfupdt_justrld = $dbh->prepare("UPDATE dcapf SET justrld=?, cfupdt=? WHERE hostname=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error: %s", $dbh->errstr);
    die;
}
my $sth_update_dcapf_setasafailover = $dbh->prepare("UPDATE dcapf SET asa_fover=? WHERE hostname=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error: %s", $dbh->errstr);
    die;
}
my $sth_update_dcapf_vtp = $dbh->prepare("UPDATE dcapf SET vtp_domain=?, vtp_mode=?, vtp_vers=?, vtp_prune=? WHERE hostname=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error: %s", $dbh->errstr);
    die;
}

my $sth_delete_cfgverpf = $dbh->prepare("DELETE FROM cfgverpf WHERE hostname=? AND typ=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error: %s", $dbh->errstr);
    die;
}
my $sth_insert_cfgverpf = $dbh->prepare("INSERT INTO cfgverpf (hostname, typ, lineno, line) VALUES (?, ?, ?, ?)");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error: %s", $dbh->errstr);
    die;
}

my $sth_delete_acdcapf = $dbh->prepare("DELETE FROM acdcapf WHERE hostname=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error: %s", $dbh->errstr);
    die;
}
my $sth_insert_acdcapf = $dbh->prepare("INSERT INTO acdcapf (hostname, ac_type, ac_ver) VALUES (?, ?, ?)");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error: %s", $dbh->errstr);
    die;
}

my $sth_delete_vlanpf = $dbh->prepare("DELETE FROM vlanpf WHERE hostname=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error: %s", $dbh->errstr);
    die;
}
my $sth_insert_vlanpf = $dbh->prepare("INSERT INTO vlanpf (hostname, descr, vlan) VALUES (?, ?, ?)");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error: %s", $dbh->errstr);
    die;
}

my $sth_select_count_hostname_scm = $dbh->prepare("SELECT COUNT(hostname) FROM hstpf WHERE hostname=? FOR READ ONLY");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error: %s", $dbh->errstr);
    die;
}


# Prepare reusable timestamp formatting.
my $time_parser_config = DateTime::Format::Strptime->new(
    pattern => "%T %Z %a %b %d %Y",
);
my $time_parser_config_nexus = DateTime::Format::Strptime->new(
    pattern => "%a %b %d %T %Y",
);
my $time_parser_flash = DateTime::Format::Strptime->new(
    pattern => "%b %d %Y %T %z",
);
my $time_formatter_db2ts = DateTime::Format::Strptime->new(
    pattern => "%Y-%m-%d-%H.%M.%S.000000",
);

# ----------------------------------------------------------------------------------------------------------------------------------

# Prepare work dir for CVS/git.
if ( $do_scm == 1 ) {
    $scmtmp = tempdir( "/tmp/cisco-erfassung-XXXXXX", CLEANUP => $cleanup );
    syslog(LOG_DEBUG, "SCM: prepare work dir '%s'", $scmtmp);
    if ( $use_git == 1 ) {
        $retval = system('cd ' . $scmtmp . '&& git clone -q ' . $giturl );
        $retval = ($retval >> 8);
        if ( $retval != 0 ) {
            syslog(LOG_NOTICE, "SCM: error %d while cloning, skipping SCM functions", $retval);
            $do_scm = 0;
        } else {
            $giturl =~ /^git@\S+:\S+\/(\S+)\.git$/;
            if ( defined($1) ) {
                $scmtmp = sprintf("%s/%s", $scmtmp, $1);
                syslog(LOG_DEBUG, "SCM: real work dir is '%s'", $scmtmp);
            } else {
                syslog(LOG_NOTICE, "SCM: unable to deduce local directory from git URL, skipping scm functions");
                $do_scm = 0;
            }
        }
    } else {
        $retval = system('cd ' . $scmtmp . '&& cvs -Q co ' . $cvsproject);
        $retval = ($retval >> 8);
        if ( $retval != 0 ) {
            syslog(LOG_NOTICE, "SCM: could not extract repository into '%s', return value %d. Skipping scm functions",
                $scmtmp, $retval);
            $do_scm = 0;
        } else {
            $scmtmp = sprintf("%s/%s", $scmtmp, $cvsproject);
        }
    }
    if ( ! -d $scmtmp ) {
        syslog(LOG_NOTICE, "SCM: could not find local checkout directory '%s', skipping scm functions", $scmtmp);
        $do_scm = 0;
    }
}

# ------------------------------------------------------------------------------

# Prepare host-loop.
syslog(LOG_DEBUG, "Host loop: prepare");
if ( defined($ARGV[0]) ) {
    # Prevent SQL injection, and push fixed strings to array. Then build SQL string.
    foreach $param (@ARGV) {
        $param =~ tr/A-Za-z0-9\-\.://dc;
        push(@params, $param);
    }
    $tmpline = sprintf("SELECT hostname, conn, username, passwd, enable, servtyp FROM hstpf WHERE hostname IN ('%s') FOR READ ONLY",
        join("', '", @params));

    $sth_select_hosts = $dbh->prepare($tmpline);
} else {
    # Loop through all hosts.
    $sth_select_hosts = $dbh->prepare("SELECT hostname, conn, username, passwd, enable, servtyp FROM hstpf \
        WHERE dca=1 ORDER BY hostname FOR READ ONLY");
}

# Common error handler for both occasions.
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "Host loop: SQL preparation error: %s", $dbh->errstr);
    die;
}

$sth_select_hosts->execute();
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "Host loop: SQL execution error: %s", $dbh->errstr);
    die;
}

# ------------------

# Loop thru hosts, query things, shove data around, shove into database.
while ( ($hostnameport, $conn_method, $username, $passwd, $enable, $wartungstyp) = $sth_select_hosts->fetchrow ) {
    if ( defined($dbh->errstr) ) {
        syslog(LOG_ERR, "Host loop: SQL fetch error: %s", $dbh->errstr);
        die;
    }

    # Validate database data. Fix blanks at end of string. `chomp` doesn't work.
    @errtyp = ();
    $errcount = 0;
    if ( $hostnameport ) {
        $hostnameport =~ /^(\S+)\s*$/;
        $hostnameport = $1;
    } else {
        push(@errtyp, 'hostnameport');
        $errcount++;
    }
    if ( $conn_method ) {
        $conn_method =~ /^(\S+)\s*$/;
        $conn_method = $1;
    } else {
        push(@errtyp, 'conn_method');
        $errcount++;
    }
    if ( $username ) {
        $username =~ /^(\S+)\s*$/;
        $username = $1;
    } else {
        push(@errtyp, 'username');
        $errcount++;
    }
    if ( $passwd ) {
        $passwd =~ /^(\S+)\s*$/;
        $passwd = $1;
    } else {
        push(@errtyp, 'passwd');
        $errcount++;
    }
    if ( $wartungstyp ) {
        $wartungstyp =~ /^(\S+)\s*$/;
        $wartungstyp = $1;
    } else {
        push(@errtyp, 'wartungstyp');
        $errcount++;
    }
    if ( $errcount > 0 ) {
        syslog(LOG_WARNING, "%s: database entry lacks mandatory fields %s; skipping host", $hostnameport, join(', ', @errtyp));
        next;
    }

    # Fix optional field.
    if ( $enable ) {
        $enable =~ /^(\S+)\s*$/;
        $enable = $1;
    }

    # Check for valid wartungstyp.
    if ( $wartungstyp ne 'IOS' && $wartungstyp ne 'UBI' && $wartungstyp ne 'NEX' && $wartungstyp ne 'ASA' ) {
        syslog(LOG_WARNING, "%s: database entry has unknown wartungstyp '%s', skipping host", $hostnameport, $wartungstyp);
        next;
    }

    # Extract Port to connect to.
    if ( $hostnameport =~ /^(\S+):(\d+)$/ ) {
       $hostname = $1;
       $hostport = $2;
    } else {
       $hostname = $hostnameport;
       $hostport = undef;
    }
    if ( defined($hostport) ) {
        syslog(LOG_DEBUG, "Host loop: connect to %s on port %d using %s, wartungstyp %s",
            $hostname, $hostport, $conn_method, $wartungstyp);
    } else {
        syslog(LOG_DEBUG, "Host loop: connect to %s using %s, wartungstyp %s", $hostname, $conn_method, $wartungstyp);
    }


    # Clear vars from previous iteration.
    # FIXME: How to make sure this list is complete?
    $ac_type = $ac_ver = $ac_ver = $asa_dm_ver = $asa_fover = $asa_serno = $cfsavd = $cfupdt = $cfsavd_flash = $confreg = $flash =
        $inv_descr = $inv_name = $inv_pid = $inv_serno = $inv_vid = $just_reloaded = $model = $ram = $reload_reason = $romver =
        $serno = $stamp = $sysimg = $time_dtf = $uptime = $uptime_min = $version = $vlan_descr = $vlan_no= $vtp_domain = $vtp_mode =
        $vtp_prune = $vtp_vers = undef;

    # Clear call array for telnet/ssh by expect from stray entries of former run.
    @cnh_parms = ();

    # Predefine variables for indicating we had a certain line in a multiline array. Default is no = 0.
    $found__no_config_chance_since_restart = $found__cfgsavd_in_running_cfg = 0;


    # Connect and try to log in.
    if ( $conn_method eq "telnet" ) {
        push(@cnh_parms, $hostname);
        if ( $hostport ) {
            push(@cnh_parms, $hostport);
        }
        $cnh = Expect->spawn("/usr/bin/telnet", @cnh_parms);
        $cnh->log_stdout(0);
        $cnh->exp_internal(0);

        for( $loopcount = 0; $loopcount < 3; $loopcount++ ) {
            ($pat, $err, $match, $before, $after) = $cnh->expect(4,
                'Username:',
                'Password:');
            if ( ! defined($err) ) {
                if ( $pat eq 1 ) {
                    $cnh->send($username . "\n");
                } elsif ( $pat eq 2 ) {
                    $cnh->send($passwd . "\n");
                    last;
                }
            } else {
                $cnh->soft_close();
                $errcount++;
                # Jump out of current loop only.
                last;
            }
        }

        if ( $errcount > 0 ) {
            if ( $quiet_mode == 0 ) {
                syslog(LOG_WARNING, "%s: connect: expect error %s handling telnet login, skipping host", $hostnameport, $err);
            }
            # Now we can safely jump to the next host in the list.
            next;
        }

        if ( $loopcount > 2 ) {
            syslog(LOG_WARNING, "%s: connect: unable to enter password after %d tries, skipping host", $hostnameport, $loopcount);
            $cnh->soft_close();
            next;
        }
    } elsif ( $conn_method eq "ssh" ) {
        if ( $hostport ) {
            push(@cnh_parms, "-p " . $hostport);
        }
        push(@cnh_parms, $username . "@" . $hostname);
        $cnh = Expect->spawn("/usr/bin/ssh", @cnh_parms);
        $cnh->log_stdout(0);
        $cnh->exp_internal(0);

        # Clear any requests from ssh in a loop until we have a defined $pat
        # FIXME: Catch more fatal ssh errors and properly act and report,
        #        - key changed
        #        - key mismatch for IP/hostname entry
        for( $loopcount = 0; $loopcount < 5; $loopcount++ ) {
            ($pat, $err, $match, $before, $after) = $cnh->expect(30, '-re',
                '(\S+ )?[Pp]assword:',
                'Are you sure you want to continue connecting',
                '% Authorization failed\.');
            if ( ! defined($err) ) {
                if ( $pat eq 1 ) {
                    $cnh->send($passwd . "\n");
                    last;
                } elsif ( $pat eq 2 ) {
                    $cnh->send("yes\n");
                } elsif ( $pat eq 3 ) {
                    syslog(LOG_WARNING, "%s: connect: failed local authorization, skipping host", $hostnameport);
                    $cnh->soft_close();
                    next;
                }
            } else {
                $cnh->soft_close();
                $errcount++;
                # Jump out of current loop only.
                last;
            }
        }

        if ( $errcount > 0 ) {
            if ( $quiet_mode == 0 ) {
                syslog(LOG_WARNING, "%s: connect: expect error handling initial ssh login, skipping host", $hostnameport);
            }
            # Now we can safely jump to the next host in the list.
            next;
        }

        if ( $loopcount > 4 ) {
            syslog(LOG_WARNING, "%s: connect: unable to enter password after %d tries, skipping host", $hostnameport, $loopcount);
            $cnh->soft_close();
            next;
        }
    } else {
        syslog(LOG_WARNING, "%s: connect: unknown connection method %s, skipping host", $hostnameport, $conn_method);
        next;
    }

    # If we can't log in, skip further processing for that host.
    if ( defined($err) ) {
        if ( $quiet_mode == 0 ) {
            syslog(LOG_WARNING, "%s: connect: expect error %s encountered when spawning %s, skipping host",
                $hostnameport, $err, $conn_method);
        }
        next;
    }

    # If we do not have a valid connection handle, try next device.
    if ( ! defined($cnh) ) {
        syslog(LOG_WARNING, "%s: connect: could not obtain Expect-Handle, skipping host", $hostnameport);
        next;
    }

    # --------------------------------------------------------------------------

    # Common I/O for both telnet and ssh.
    ($pat, $err, $match, $before, $after) = $cnh->expect(5,
        '-re', '^.*>\s?$',
        '-re', '^.*\#\s?$'
    );

    # Handle Connection timeouts properly?
    if ( ! defined($pat) ) {
        syslog(LOG_WARNING, "%s: connect: timeout while waiting for command line prompt, skipping host", $hostnameport);
        $cnh->soft_close();
        next;
    }

    # Handle enabling of the user.
    if ( $pat eq 1 ) {
        if ( $enable ) {
            $cnh->send("enable\n");
            $cnh->expect(5, '-re', '^\s*Password: \s?$');
            if ( defined($err) ) {
                # Usually this means we've lost the connection to the device and is always fatal => Skip host.
                syslog(LOG_WARNING, "%s: connect: timeout waiting for enable password prompt, skipping host", $hostnameport, $err);
                $cnh->soft_close();
                next;
            }

            $cnh->send($enable . "\n");
        } else {
            syslog(LOG_WARNING, "%s: connect: need to send 'enable' but is not defined in database, skipping host", $hostnameport);
            $cnh->send("exit\n");
            $cnh->soft_close();
            next;
        }

    } else {
        # Just press return - altering send/expect is mandatory.
        $cnh->send("\n");
    }

    $cnh->expect(5, '-re', $prompt_re);
    if ( defined($err) ) {
        # Usually this means we've lost the connection to the device and is always fatal => Skip host.
        syslog(LOG_WARNING, "%s: connect: timeout waiting for enabled prompt, skipping host", $hostnameport, $err);
        $cnh->soft_close();
        next;
    }

    # Switch off interactive pager.
    if ( $wartungstyp eq 'ASA' ) {
        $cnh->send("terminal pager 0\n");
    } else {
        $cnh->send("terminal length 0\n");
    }
    $cnh->expect(5, '-re', $prompt_re);
    if ( defined($err) ) {
        # Usually this means we've lost the connection to the device and is always fatal => Skip host.
        syslog(LOG_WARNING, "%s: connect: timeout disabling paginator, skipping host", $hostnameport, $err);
        $cnh->soft_close();
        next;
    }

    # ----------------------------------------------------------------------

    # Handle show inventory.
    # Note: IOS 12.0 and earlier don't know this command.

    syslog(LOG_DEBUG, "%s: show inventory: sending command 'show inventory' and parsing output", $hostnameport);
    $cnh->send("show inventory\n");
    ($pat, $err, $match, $before, $after) = $cnh->expect(5, '-re', $prompt_re);

    if ( ! defined($err) ) {
        syslog(LOG_DEBUG, "%s: show inventory: deleting previous data", $hostnameport);
        $sth_delete_invpf->execute($hostnameport);
        if ( defined($dbh->errstr) ) {
            syslog(LOG_NOTICE, "%s: show inventory: SQL execution error deleting previous data: %s", $hostnameport, $dbh->errstr);
        } else {
            # Set defaults for our parser helpers.
            $inv_have_line_name = $inv_have_line_pid = 0;

            # Filter nasty (un)printables. Keep CR, so we're able to detect an empty line.
            $before =~ tr/\000-\010|\013-\014|\016-\037|\177-\377//d;

            @beforeLinesArray = split("\n", $before);
            foreach $line (@beforeLinesArray) {
                # Try to match our line type: Name, Pid, or empty. Everything else is ignored.
                if ( $line =~ /^\s*$/ ) {
                    # Check if we have everything for a DB insert.
                    if ( $inv_have_line_name == 1 && $inv_have_line_pid == 1 ) {
                        if ( ! defined($inv_pid) || $inv_pid =~ /^\s*$/ ) {
                            $inv_pid = 'Unspecified';
                        }
                        if ( ! defined($inv_vid) || $inv_vid =~ /^\s*$/ ) {
                            $inv_vid = 'Unspecified';
                        }
                        if ( ! defined($inv_serno) || $inv_serno =~ /^\s*$/ ) {
                            $inv_serno = 'Unspecified';
                        }

                        # Extract ASA hardware serial number from here.
                        if ( $wartungstyp eq 'ASA' && $inv_name eq 'Chassis' ) {
                            syslog(LOG_DEBUG, "%s: show inventory: found ASA serial number %s", $hostnameport, $inv_serno);
                            $asa_serno = $inv_serno;
                        }

                        $sth_insert_invpf->execute($hostnameport, $inv_name, $inv_descr, $inv_pid, $inv_vid, $inv_serno);
                        if ( defined($dbh->errstr) ) {
                            syslog(LOG_NOTICE, "%s: show inventory: SQL execution error inserting data: %s",
                                $hostnameport, $dbh->errstr);
                            last;
                        }

                        # Reset Variables for next run.
                        $inv_name = $inv_descr = $inv_pid = $inv_vid = $inv_serno = undef;
                        $inv_have_line_name = $inv_have_line_pid = 0;
                    }
                } elsif ( $line =~ /^NAME: "(.*)", DESCR: "(.*)"\s*$/i ) {
                    $inv_have_line_name = 1;
                    $inv_name = $1;
                    $inv_descr = $2;
                } elsif ( $line =~ /^PID: (\S*)\s*, VID: (.*)\s*, SN: (.*)\s*$/ ) {
                    $inv_have_line_pid = 1;

                    # Fix excess blanks at string end.
                    $inv_pid = $1;
                    $inv_pid =~ tr/[ ]*$//d;

                    $inv_vid = $2;
                    $inv_vid =~ tr/[ ]*$//d;

                    $inv_serno = $3;
                    $inv_serno =~ tr/[ ]*$//d;
                } elsif ( $line =~ /^% Invalid input detected at '^' marker\.$/ ) {
                    syslog(LOG_NOTICE, "%s: show inventory: device doesn't support command: %s", $hostnameport);
                    last;
                }
            }
        }
    } else {
        syslog(LOG_WARNING, "%s: show inventory: expect error %s encountered while trying command, skipping host",
            $hostnameport, $err);
        # Usually this means we've lost the connection to the device and is always fatal => Skip host.
        $cnh->soft_close();
        $dbh->do("rollback");
        next;
    }

    # ----------------------------------------------------------------------

    # Obtain various information from flash (permanent storage) memory.

    # Some newer devices insist on flash: (with colon) here. Do that in a loop and jump out if we have what we want.
    @try_loop_strings = ('show flash', 'show flash:', 'show bootflash:', 'dir flash:');
    foreach $try_loop_string (@try_loop_strings) {
        $cnh->send($try_loop_string . "\n");
        ($pat, $err, $match, $before, $after) = $cnh->expect(5, '-re', $prompt_re);

        if ( ! defined($err) ) {
            # Filter nasty (un)printables.
            $before =~ tr/\000-\010|\013-\037|\177-\377//d;

            @beforeLinesArray = split("\n", $before);
            # Get flash memory size.
            foreach $line (@beforeLinesArray) {
                # Try to determine the flash memory size.
                if ( $line =~ /^(\d+) bytes total \(\d+ bytes free(\/\d+% free)?\)\s*$/ ) {
                    syslog(LOG_DEBUG, "%s: flash: size: match(1): %s Bytes", $hostnameport, $1);
                    $flash_size = sprintf("%.0f", $1 / 1024 / 1024);
                    last;
                } elsif ( $line =~ /^(\d+) bytes available \((\d+) bytes used\)\s*$/ ) {
                    if ( defined($1) && defined($2) ) {
                        syslog(LOG_DEBUG, "%s: flash: size: match(2): Available: %s Bytes, Used: %s Bytes",
                            $hostnameport, $1, $2);
                        $flash_size = sprintf("%.0f", ($1 + $2) / 1024 / 1024);
                        last;
                    } else {
                        syslog(LOG_NOTICE, "%s: flash: size NOT read from %s, because it is malformed. (%s, %s)",
                            $hostnameport, $try_loop_string, $1, $2);
                    }
                }
            }
            if ( defined($flash_size) ) {
                syslog(LOG_DEBUG, "%s: flash: found flash size to be %s MiB", $hostnameport, $flash_size);
            }

            # Get file date of nvram_config.
            foreach $line (@beforeLinesArray) {
                if ( $wartungstyp eq 'IOS' ) {
                    if ( $line =~ /^\s+\d+\s+\d+\s+(\S{3} \d{2} \d{4}) (\d{2}:\d{2}:\d{2})\.\d{10} (\S+)\s+nvram_config\s*$/ ) {
                        # This is for show commands.
                        syslog(LOG_DEBUG, "%s: flash: extracting saved config timestamp: %s %s %s (with '%s')",
                            $hostnameport, $1, $2, $3, $try_loop_string);
                        $time_dtf = $time_parser_flash->parse_datetime($1 . ' ' . $2 . ' '  . $3);
                        if ( ! defined($time_dtf) ) {
                            syslog(LOG_DEBUG, "%s: flash: unable to extract saved config timestamp (%s)",
                                $hostnameport, $try_loop_string);
                        }
                    } elsif ( $line =~ /^\d+\s+-rw-\s+\d+\s+(\S{3} \d{1,2} \d{4}) (\d{2}:\d{2}:\d{2} \S+)\s+nvram_config\s*$/ ) {
                        # This is for 'dir flash:'.
                        syslog(LOG_DEBUG, "%s: flash: extracting saved config timestamp: %s %s (with '%s')",
                            $hostnameport, $1, $2, $try_loop_string);
                        $time_dtf = $time_parser_flash->parse_datetime($1 . ' ' . $2);
                        if ( ! defined($time_dtf) ) {
                            syslog(LOG_DEBUG, "%s: flash: unable to extract saved config timestamp (%s)",
                                $hostnameport, $try_loop_string);
                        }
                    }
                } 
            }
        } else {
            syslog(LOG_WARNING, "%s: flash: expect error %s encountered while trying '%s'",
                $hostnameport, $err, $try_loop_string);
            $cnh->soft_close();
            # Undo DB changes and try next host in list.
            $dbh->do("rollback");
            $errcount++;
            last;
        }

        # If there was an error before, or we have what we need, no need to iterate through another try.
        if ( $errcount++ > 0 || (defined($flash_size) && defined($time_dtf)) ) {
            last;
        }

        # Format time from earlier found input.
        if ( $wartungstyp eq 'IOS' && defined($time_dtf) ) {
            $cfsavd_flash = $time_formatter_db2ts->format_datetime($time_dtf);
            syslog(LOG_DEBUG, "%s: flash: using formatted date '%s'", $hostnameport, $cfsavd_flash);
        }
    }
    $errcount = 0;

    # ----------------------------------------------------------------------

    # Show Version and parse output of it.
    syslog(LOG_DEBUG, "%s: show version: sending command 'show version' and parsing output", $hostnameport);
    $cnh->send("show version\n");
    ($pat, $err, $match, $before, $after) = $cnh->expect(5, '-re', $prompt_re);

    if ( ! defined($err) ) {
        # Filter nasty (un)printables. Keep CR, so we have array entries for "empty" lines.
        # Note: 10 = 0xa = 012 = LF
        #       13 = 0xd = 015 = CR
        $before =~ tr/\000-\010|\013-\014|\016-\037|\177-\377//d;

        # See if we can parse the content of $before (containing show version result).
        @show_version = split("\n", $before);
        foreach $line (@show_version) {
            # Remove CR line by line for parsing into the database, but leave it in the array for later raw text insert.
            $line =~ tr/\015//d;

            # FIXME: How can we make these lines shorter to fit in 132 chars in a pretty way?
            if ( $wartungstyp eq 'IOS' ) {
                if ( $line =~ /^(Cisco )?IOS(-XE)? (Software( \[\S+\])?,|\(tm\)) .* Software \((\S+)\), Version ([0-9A-Za-z\.\(\)]+)[,]? RELEASE SOFTWARE \(fc\d+\)\s*$/ ) {
                    $showverfeature = $5;
                    $version = $6;
                } elsif ( $line =~ /^ROM: Bootstrap program is (C\d{4} boot loader)\s*$/ ) {
                    $romver = $1;
                } elsif ( $line =~ /^ROM: System Bootstrap, Version (\S+), RELEASE SOFTWARE \(fc\d\)\s*$/ ) {
                    $romver = $1;
                } elsif ( $line =~ /^ROM: (\S+)\s*$/ ) {
                    $romver = $1;
                } elsif ( $line =~ /^[Cc]isco\s+(\S+)\s+(\(.+\)\s+processor\s+)?(\(revision \S+\))?\s?+with\s+(\d+)K(\/(\d+)K)?\s+bytes\s+of\s+(physical )?memory\.\s*$/ ) {
                    $model = $1;
                    $ram = $4;
                    # Add iomem, if avail.
                    if ( $6 ) {
                        $ram = $ram + $6;
                    }
                    $ram = sprintf("%.0f", $ram / 1024);
                } elsif ( $line =~ /^(\d+)K bytes of physical memory\.\s*$/ ) {
                    # This takes precedence above the IOS derived data - for XE devices.
                    $ram = sprintf("%.0f", $1 / 1024);
                } elsif ( $line =~ /^System image file is "(\S+)"(, booted via flash)?\s*$/ ) {
                    $sysimg = $1;
                } elsif ( $line =~ /^(Processor board ID|Motherboard serial number:) (\w+)( \(\w+\))?(, with hardware revision \w+)?\s*$/ ) {
                    $serno = $2;
                } elsif ( $line =~ /^(\d+)K bytes of [Ff]lash (memory )?at (boot)?flash:\.\s*$/
                        || $line =~ /^(\d+)K bytes of processor board System flash \(Read ONLY\)\s*$/
                        || $line =~ /^(\d+)K bytes (of (processor board \w+ flash|ATA (System )?CompactFlash) (\d )?\((Read\/Write|Intel Strataflash)\)|system flash allocated)\s*$/ ) {
                    $flash = sprintf("%.0f", $1 / 1024);
                } elsif ( $line =~ /^\S+ uptime is (.+)\s*$/ ) {
                    $uptime = $1;
                } elsif ( $line =~ /^System returned to ROM by (\S+)\s*$/ ) {
                    $reload_reason = $1;
                } elsif ( $line =~ /^System restarted (by )?(\S+) at/ ) {
                    $reload_reason = $2;
                } elsif ( $line =~ /^Configuration register is (\w+)( \(will be \w+ at next reload\))?\s*$/ ) {
                    $confreg = $1;
                }
            } elsif ( $wartungstyp eq 'ASA' ) {
                if ( $line =~ /^Cisco Adaptive Security Appliance Software Version (\S+)\s*$/ ) {
                    $version = $1;
                } elsif ( $line =~ /^ROMMON Version\s+: (\S+)\s*$/ ) {
                    $romver = $1;
                } elsif ( $line =~ /^Device Manager Version (\S+)\s*$/ ) {
                    $asa_dm_ver = $1;
                } elsif ( $line =~ /^Hardware:\s+(\S+), (\d+) MB RAM/ ) {
                    $model = $1;
                    $ram = $2;
                } elsif ( $line =~ /^\S+ up (.+)\s*$/ ) {
                    $uptime = $1
                } elsif ( $line =~ /^System image file is "(\S+)"\s*$/ ) {
                    $sysimg = $1;
                } elsif ( $line =~ /^Internal ATA Compact Flash, (\d+)MB\s*$/ ) {
                    $flash = $1;
                } elsif ( $line =~ /^Configuration register is (\w+)\s*$/ ) {
                    $confreg = $1;
                }
            } elsif ( $wartungstyp eq 'UBI' ) {
                # Note: Currently untested due to lack of machines.
                if ( $line =~ /^Machine Model[\.]+\s+(\S+)\s*$/ ) {
                    $model = $1;
                } elsif ( $line =~ /^Serial Number[\.]+\s+(\S+)\s*$/ ) {
                    $serno = $1;
                } elsif ( $line =~ /^Software Version[\.]+\s+(\S+)\s*$/ ) {
                    $version = $1;
                }
                $confreg = $sysimg = $uptime = "Unkn.";
                $flash = $ram = 1;
            } elsif ( $wartungstyp eq 'NEX' ) {
                if ( $line =~ /^\s+system:\s+version (\S+)\s*$/ ) {
                    $version = $1;
                } elsif ( $line =~ /^\s+cisco Nexus (\S+) Chassis.*$/ ) {
                    $model = sprintf("Nexus %s", $1);
                } elsif ( $line =~ /^.* with (\d+) kB of memory\.\s*$/ ) {
                    $ram = sprintf("%.0f", $1 / 1024);
                } elsif ( $line =~ /^\s+bootflash:\s+(\d+) kB\s*$/ ) {
                    $flash = sprintf("%.0f", $1 / 1024);
                } elsif ( $line =~ /^\s+Processor Board ID (\w+)\s*$/) {
                    $serno = $1;
                } elsif ( $line =~ /^\s+system image file is:\s+(\S+)\s*$/ ) {
                    $sysimg = $1;
                } elsif ( $line =~ /^Kernel uptime is (.*)\s*$/ ) {
                    $uptime = $1;
                } elsif ( $line =~ /^Reason: (.*)\s*$/ ) {
                    $reload_reason = $1;
                }
            }
        }

        # --------------------------

        # Save raw text of 'show version' to database.

        syslog(LOG_DEBUG, "%s: show version: deleting previous data", $hostnameport);
        $sth_delete_cfgverpf->execute($hostnameport, 'ver');
        if ( defined($dbh->errstr) ) {
            syslog(LOG_NOTICE, "%s: show version: SQL execution error deleting text: %s", $hostnameport, $dbh->errstr);
        } else {
            # Delete first line 'show version'.
            splice(@show_version, 0, 1);

            $lineno = 0;
            foreach $line (@show_version) {
                # Remove CR only for parsing into the database.
                $line =~ tr/\015//d;

                # Wrap long lines, database field has 131 chars (max screen width + attribute field).
                if ( length($line) gt 131 ) {
                    @lines = ( $line =~ m/.{1,131}/g );
                } else {
                    @lines = ( $line );
                }
                foreach $tmpline (@lines) {
                    $lineno++;
                    $sth_insert_cfgverpf->execute($hostnameport, 'ver', $lineno, $tmpline);

                    # Terminate inner loop if there was an error.
                    if ( defined($dbh->errstr) ) {
                        syslog(LOG_NOTICE, "%s: show version: SQL execution error inserting text line: %s",
                            $hostnameport, $dbh->errstr);
                        $errcount++;
                        last;
                    }
                }

                # Terminate outer loop if there was an error.
                if ( $errcount > 0 ) {
                    last;
                }
            }
        }
        syslog(LOG_DEBUG, "%s: show version: saved %d lines to database", $hostnameport, $lineno);
    } else {
        syslog(LOG_WARNING, "%s: show version: expect error %s encountered while trying command, skipping host",
            $hostnameport, $err);
        # Usually this means we've lost the connection to the device and is always fatal => Skip host.
        # Note: this is the global skip if expect for 'show version' goes wrong.
        $cnh->soft_close();
        $dbh->do("rollback");
        next;
    }

    # ----------------------------------------------------------------------

    # Calculate Uptime in Minutes, for our statistics.

    $uptime_min = 0;
    if ( defined($uptime) ) {
        syslog(LOG_DEBUG, "%s: uptime: calculating numeric representation", $hostnameport);
        if ( $wartungstyp eq 'IOS' ) {
            if ( $uptime =~ /^(([0-9]+)? year[s]?, )?(([0-9]+)? week[s]?, )?(([0-9]+)? day[s]?, )?(([0-9]+)? hour[s]?, )?(([0-9]+)? minute[s]?)?$/ ) {
                if ( defined($2) ) {
                    $uptime_min = $uptime_min + ($2 * 524160);
                }
                if ( defined($4) ) {
                    $uptime_min = $uptime_min + ($4 * 10080);
                }
                if ( defined($6) ) {
                    $uptime_min = $uptime_min + ($6 * 1440);
                }
                if ( defined($8) ) {
                    $uptime_min = $uptime_min + ($8 * 60);
                }
                if ( defined($10) ) {
                    $uptime_min = $uptime_min + $10;
                }
            }
        } elsif ( $wartungstyp eq 'ASA' ) {
            if ( $uptime =~ /^(([0-9]+)? day[s]? )?(([0-9]+)? hour[s]?)$/ ) {
                if ( defined($2) ) {
                    $uptime_min = $uptime_min + ($2 * 1440);
                }
                if ( defined($4) ) {
                    $uptime_min = $uptime_min + ($4 * 60);
                }
            }
        } elsif ( $wartungstyp eq 'NEX' ) {
            if ( $uptime =~ /^([0-9]+)? day\(s\), ([0-9]+)? hour\(s\), ([0-9]+)? minute\(s\), ([0-9]+)? second\(s\)$/ ) {
                if ( defined($1) ) {
                    $uptime_min = $uptime_min + ($1 * 1440);
                }
                if ( defined($2) ) {
                    $uptime_min = $uptime_min + ($2 * 60);
                }
                if ( defined($3) ) {
                    $uptime_min = $uptime_min + $3;
                }
            }
        }
    } else {
        syslog(LOG_NOTICE, "%s: uptime: has not been found, calculation of uptime_min impossible, skipping function",
            $hostnameport);
    }

    # ----------------------------------------------------------------------

    # Check if we don't know the size of flash mem from show ver. Happens with some switches and other oddities.
    if ( ! defined($flash) ) {
        syslog(LOG_DEBUG, "%s: show version: no flash information found in 'show version', using information from flash commands",
            $hostnameport);
        if ( defined($flash_size) ) {
            $flash = $flash_size;
        }
    }

    # Extract ASA hardware serial number from 'show inventory'.
    if ( $wartungstyp eq 'ASA' ) {
        if ( defined($asa_serno) ) {
            $serno = $asa_serno;
        }
    }


    # Check if we have all mandatory variables filled from 'show version'.
    syslog(LOG_DEBUG, "%s: show version: checking completeness of 'show version' derived variables", $hostnameport);
    @errtyp = ();
    $errcount = 0;
    if ( ! defined($version) ) {
        push(@errtyp, 'version');
        $errcount++;
    }

    if ( ! defined($model) ) {
        push(@errtyp, 'model');
        $errcount++;
    }

    if ( ! defined($ram) ) {
        push(@errtyp, 'ram');
        $errcount++;
    }

    if ( ! defined($flash) ) {
        push(@errtyp, 'flash');
        $errcount++;
    }

    if ( ! defined($serno) ) {
        push(@errtyp, 'serno');
        $errcount++;
    }

    if ( $errcount > 0 ) {
        syslog(LOG_WARNING, "%s: show version: collected data lacks mandatory fields %s; skipping host",
            $hostnameport, join(', ', @errtyp));
        # Undo possible changes and try next host in list.
        $cnh->soft_close();
        $dbh->do("rollback");
        next;
    }

    # Prepare database fields for later setting to true NULL.
    if ( ! defined($asa_dm_ver) ) {
        $asa_dm_ver = 'NULL';
    }
    if ( ! defined($asa_fover) ) {
        $asa_fover = 'NULL';
    }
    if ( ! defined($confreg) ) {
        $confreg = 'NULL';
    }
    if ( ! defined($reload_reason) ) {
        $reload_reason = 'NULL';
    }
    if ( ! defined($romver) ) {
        $romver = 'NULL';
    }
    if ( ! defined($sysimg) ) {
        $sysimg = 'NULL';
    }
    if ( ! defined($uptime) ) {
        $uptime = 'NULL';
    }


    # Delete old entry in database.
    syslog(LOG_DEBUG, "%s: show version: deleting old data from dcapf", $hostnameport);
    $sth_delete_dcapf->execute($hostnameport);
    if ( defined($dbh->errstr) ) {
        syslog(LOG_NOTICE, "%s: show version: SQL execution error deleting dcapf: %s", $hostnameport, $dbh->errstr);
        $errcount++;
    } else {
        # Prepare timestamps for, well, timestamps. In the database, that is.
        @time_tm = localtime();
        $stamp = strftime('%Y-%m-%d-%H.%M.%S.000000', @time_tm);

        # Deletion succeeded, continue with insert.
        syslog(LOG_DEBUG, "%s: show version: inserting fresh data into dcapf", $hostnameport);
        $sth_insert_dcapf->execute($confreg, $flash, $hostnameport, $model, $ram, $romver, $serno, $stamp, $sysimg, $uptime, 
            $uptime_min, $version, $asa_dm_ver, $reload_reason);
        if ( defined($dbh->errstr) ) {
            syslog(LOG_WARNING, "%s: show version: SQL execution error inserting into dcapf: %s, skipping host",
                $hostnameport, $dbh->errstr);
            $cnh->soft_close();
            $dbh->do("rollback");
            next;
        }
    }

    # ----------------------------------------------------------------------

    # Handle show failover - for ASA only.
    if ( $wartungstyp eq 'ASA' ) {
        syslog(LOG_DEBUG, "%s: failover: sending command 'show failover' and parsing output", $hostnameport);
        $cnh->send("show failover\n");
        ($pat, $err, $match, $before, $after) = $cnh->expect(5, '-re', $prompt_re);

        if ( ! defined($err) ) {
            # Filter nasty (un)printables.
            $before =~ tr/\000-\010|\013-\037|\177-\377//d;

            # Loop through lines.
            @beforeLinesArray = split("\n", $before);
            foreach $line (@beforeLinesArray) {
                if ( $line =~ /^Failover (On|Off)\s*$/ ) {
                    if ( $1 eq "On" ) {
                        $sth_update_dcapf_setasafailover->execute('1', $hostnameport);
                    } elsif ( $1 eq "Off" ) {
                        $sth_update_dcapf_setasafailover->execute('0', $hostnameport);
                    }
                    if ( defined($dbh->errstr) ) {
                        syslog(LOG_NOTICE, "%s: failover: SQL execution error: %s", $hostnameport, $dbh->errstr);
                    }
                    last;
                }
            }
        } else {
            syslog(LOG_WARNING, "%s: failover: expect error %s encountered while trying 'show failover', skipping host",
                $hostnameport, $err);
            # Usually this means we've lost the connection to the device and is always fatal => Skip host.
            $cnh->soft_close();
            $dbh->do("rollback");
            next;
        }
    }

    # ----------------------------------------------------------------------

    # VTP config.
    #
    # FIXME: We should possibly implement this also for NEX.

    if ( $wartungstyp eq 'IOS' ) {
        syslog(LOG_DEBUG, "%s: vtp: sending command 'show vtp status' and parsing output", $hostnameport);
        $cnh->send("show vtp status\n");
        ($pat, $err, $match, $before, $after) = $cnh->expect(5, '-re', $prompt_re);

        if ( ! defined($err) ) {
            # Filter nasty (un)printables.
            $before =~ tr/\000-\010|\013-\037|\177-\377//d;

            @beforeLinesArray = split("\n", $before);
            foreach $line (@beforeLinesArray) {
                if ( $line =~ /^VTP version running\s+: (\d)$/ ) {
                    if ( defined($1) ) {
                        $vtp_vers = $1;
                    } else {
                        $vtp_vers = -1;
                    }
                } elsif ( $line =~ /^VTP Domain Name\s+: (\S+)$/ ) {
                    if ( defined($1) ) {
                        $vtp_domain = $1;
                    } else {
                        $vtp_domain = 'NULL';
                    }
                } elsif ( $line =~ /^VTP Pruning Mode\s+: (\S+)$/ ) {
                    if ( defined($1) ) {
                        $vtp_prune = $1;
                        if ( $vtp_prune eq "Enabled" ) {
                            $vtp_prune = '1';
                        } elsif ( $vtp_prune eq "Disabled" ) {
                            $vtp_prune = '0';
                        } else {
                            $vtp_prune = ' ';
                        }
                    } else {
                        $vtp_prune = ' ';
                    }
                } elsif ( $line =~ /^VTP Operating Mode\s+: (\S+)$/ ) {
                    if ( defined($1) ) {
                        $vtp_mode = $1;
                    } else {
                        $vtp_mode = 'NULL';
                    }
                } elsif ( $line =~ /^% Invalid input detected at '^' marker\.$/ ) {
                    syslog(LOG_NOTICE, "%s: vtp: device doesn't support 'show vtp status': %s", $hostnameport);
                    $errcount++;
                    last;
                }
            }

            if ( $errcount eq 0 ) {
                # Write found data into database.
                $sth_update_dcapf_vtp->execute($vtp_domain, $vtp_mode, $vtp_vers, $vtp_prune, $hostnameport);
                if ( defined($dbh->errstr) ) {
                    syslog(LOG_NOTICE, "%s: vtp: SQL execution error: %s", $hostnameport, $dbh->errstr);
                }
            }

            # Don't carry over to the next host loop.
            $vtp_vers = $vtp_domain = $vtp_prune = $vtp_mode = undef;
        } else {
            syslog(LOG_WARNING, "%s: vtp: expect error %s encountered while trying 'show vtp status', skipping host",
                $hostnameport, $err);
            # Usually this means we've lost the connection to the device and is always fatal => Skip host.
            $cnh->soft_close();
            $dbh->do("rollback");
            next;
        }
    }

    # ----------------------------------------------------------------------

    # For a wholesome device recovery, we need information about current Vlan-Configuration.
    #
    # FIXME: We should possibly implement this also for NEX.

    if ( $wartungstyp eq 'IOS' ) {
        # Delete old entries in database.
        syslog(LOG_DEBUG, "%s: vlan: deleting previous data", $hostnameport);
        $sth_delete_vlanpf->execute($hostnameport);
        if ( defined($dbh->errstr) ) {
            syslog(LOG_NOTICE, "%s: vlan: SQL execution error deleting data: %s", $hostnameport, $dbh->errstr);
            $errcount++;
        } else {
            @try_loop_strings = ('show vlan', 'show vlan-switch');
            foreach $try_loop_string (@try_loop_strings) {
                syslog(LOG_DEBUG, "%s: vlan: sending command '%s' and parsing output", $hostnameport, $try_loop_string);
                $cnh->send($try_loop_string . "\n");
                ($pat, $err, $match, $before, $after) = $cnh->expect(5, '-re', $prompt_re);

                if ( ! defined($err) ) {
                    # Filter nasty (un)printables.
                    $before =~ tr/\000-\010|\013-\037|\177-\377//d;

                    @beforeLinesArray = split("\n", $before);
                    foreach $line (@beforeLinesArray) {
                        if ( $line =~ /^(\d+)\s+(\S+)\s+active\s+/ ) {
                            if ( defined($1) && defined($2) ) {
                                $vlan_no = $1;
                                $vlan_descr = $2;

                                # Write found data into database.
                                $sth_insert_vlanpf->execute($hostnameport, $vlan_descr, $vlan_no);
                                if ( defined($dbh->errstr) ) {
                                    syslog(LOG_NOTICE, "%s: vlan: SQL execution error inserting data: %s",
                                        $hostnameport, $dbh->errstr);
                                    last;
                                }
                            }
                        } elsif ( $line =~ /^% Invalid input detected at '^' marker\.$/ ) {
                            syslog(LOG_INFO, "%s: vlan: device doesn't support '%s'", $hostnameport, $try_loop_string);
                            last;
                        }
                    }
                } else {
                    syslog(LOG_NOTICE, "%s: vlan: expect error %s encountered while trying '%s'",
                        $hostnameport, $err, $try_loop_string);
                    $errcount++;
                    last;
                }
            }
            # Don't carry over to the next host loop.
            $vlan_descr = $vlan_no = undef;
        }

        if ( $errcount > 0 ) {
            syslog(LOG_WARNING, "%s: vlan: skipping host because of earlier errors", $hostnameport);
            # Usually this means we've lost the connection to the device and is always fatal => Skip host.
            $cnh->soft_close();
            $dbh->do("rollback");
            next;
        }
    }

    # ----------------------------------------------------------------------

    # Extract actual configuration.
    if ( $wartungstyp eq 'ASA' ) {
        $show_config_command = "more system:running-config";
    } else {
        # It's much easier to get hold of startup configuration than running-config, especially on older devices.
        $show_config_command = "show startup-config";
    }
    syslog(LOG_DEBUG, "%s: config: sending command '%s' and parsing output", $hostnameport, $show_config_command);
    $cnh->send($show_config_command . "\n");

    ($pat, $err, $match, $before, $after) = $cnh->expect(5, '-re', $prompt_re);
    if ( ! defined($err) ) {
        # Filter nasty (un)printables. Don't keep CR, because config usually has no empty lines.
        $before =~ tr/\000-\010|\013-\037|\177-\377//d;
        @show_config = split("\n", $before);

        # Config usually ends with a fixed string, so we can check if the obtained configuration is complete.
        if ( ($wartungstyp eq 'IOS' || $wartungstyp eq 'UBI') && $show_config[-1] ne "end" ) {
            syslog(LOG_NOTICE, "%s: config: unexpected end of startup-config: '%s', skipping configuration handling",
                $hostnameport, $show_config[-1]);
            $errcount++;
        } elsif ( $wartungstyp eq 'ASA' && $show_config[-1] ne ": end" ) {
            syslog(LOG_NOTICE, "%s: config: unexpected end of running-config: '%s', skipping configuration handling",
                $hostnameport, $show_config[-1]);
            $errcount++;
        } elsif ( $wartungstyp eq 'NEX' && scalar @show_config < 12 ) {
            # FIXME: 12 might seem an arbitrary number, but there is no designated config end. Better ideas welcome!
            syslog(LOG_NOTICE, "%s: config: configuration has <12 lines, and ends with '%s', skipping configuration handling",
                $hostnameport, $show_config[-1]);
            $errcount++;
        }

        # Skip host host if there was an error.
        if ( $errcount > 0 ) {
            syslog(LOG_WARNING, "%s: config: skipping host because of earlier errors", $hostnameport);
            $cnh->soft_close();
            # Undo DB changes and try next host in list.
            $dbh->do("rollback");
            next;
        }

        # Save textual configuration into database. Therefore, delete previous database entries, and rewrite.
        syslog(LOG_DEBUG, "%s: config: delete previous configuration from database", $hostnameport);
        $sth_delete_cfgverpf->execute($hostnameport, 'cfg');
        if ( defined($dbh->errstr) ) {
            syslog(LOG_NOTICE, "%s: config: SQL execution error: %s", $hostnameport, $dbh->errstr);
            $errcount++;
        } else {
            $lineno = 0;
            foreach $line (@show_config) {
                # Remove CR for copying config into the database.
                $line =~ tr/\015//d;

                # Wrap long lines, database field has 131 chars (max screen width + attribute field).
                if ( length($line) gt 131 ) {
                    @lines = ( $line =~ m/.{1,131}/g );
                } else {
                    @lines = ( $line );
                }
                foreach $tmpline (@lines) {
                    $lineno++;
                    $sth_insert_cfgverpf->execute($hostnameport, 'cfg', $lineno, $tmpline);

                    # Terminate inner loop if there was an error.
                    if ( defined($dbh->errstr) ) {
                        syslog(LOG_NOTICE, "%s: config: SQL execution error inserting text line: %s",
                            $hostnameport, $dbh->errstr);
                        $errcount++;
                        last;
                    }
                }

                # Terminate outer loop if there was an error.
                if ( $errcount > 0 ) {
                    last;
                }
            }
        }

        # Terminate host loop if there was an error.
        if ( $errcount > 0 ) {
            syslog(LOG_WARNING, "%s: config: skipping host because of earlier errors", $hostnameport);
            $cnh->soft_close();
            # Undo DB changes and try next host in list.
            $dbh->do("rollback");
            next;
        } else {
            syslog(LOG_DEBUG, "%s: config: saved %d lines to database", $hostnameport, $lineno);
        }

        @lines = ();

        # --------------------------

        # List anyconnect versions. This has to be parsed from the configuration, so the actually used packages are listed!
        syslog(LOG_DEBUG, "%s: anyconnect: deleting previous data", $hostnameport);
        $sth_delete_acdcapf->execute($hostnameport);
        if ( defined($dbh->errstr) ) {
            syslog(LOG_NOTICE, "%s: anyconnect: SQL execution error: %s", $hostnameport, $dbh->errstr);
        } else {
            syslog(LOG_DEBUG, "%s: anyconnect: parse configuration data", $hostnameport);
            foreach $line (@show_config) {
                # Remove CR for parsing lines.
                $line =~ tr/\015//d;

                if ( $wartungstyp eq 'IOS' &&
                        $line =~ /^crypto vpn anyconnect flash:\/webvpn\/anyconnect-(\S+)-([\d.]+)(-webdeploy)?-k9\.pkg sequence \d+$/ ) {
                    syslog(LOG_DEBUG, "%s: anyconnect: (IOS) found '%s'", $hostnameport, $line);
                    $ac_type = $1;
                    $ac_ver = $2;
                } elsif ( $wartungstyp eq 'ASA' &&
                        $line =~ /^\s*anyconnect image disk0:\/anyconnect-(\S+)-([\d.]+)(-webdeploy)?-k9\.pkg \d+$/ ) {
                    syslog(LOG_DEBUG, "%s: anyconnect: (ASA) found '%s'", $hostnameport, $line);
                    $ac_type = $1;
                    $ac_ver = $2;
                } else {
                    $ac_type = $ac_ver = undef;
                }

                if ( defined($ac_type) && defined($ac_ver) ) {
                    syslog(LOG_DEBUG, "%s: anyconnect: insert version '%s' for type '%s'", $hostnameport, $ac_ver, $ac_type);
                    $sth_insert_acdcapf->execute($hostnameport, $ac_type, $ac_ver);
                    if ( defined($dbh->errstr) ) {
                        syslog(LOG_NOTICE, "%s: anyconnect: SQL execution error: %s", $hostnameport, $dbh->errstr);
                    }
                }

                # Don't carry over to the next loop iteration.
                $ac_type = $ac_ver = undef;
            }
        }

        # --------------------------

        # Parse saved configuration timestamp.
        syslog(LOG_DEBUG, "%s: config saved: parsing timestamp in configuration", $hostnameport);

        # Look for timestamp lines.
        foreach $line (@show_config) {
            # Remove CR for parsing lines.
            $line =~ tr/\015//d;

            if ( $wartungstyp eq 'ASA' &&
                    $line =~ /^: Written by \S+ at (\d{2}:\d{2}:\d{2})\.\d{3} (\S+ \S{3} \S{3} \d{1,2} \d{4})$/ ) {
                $time_dtf = $time_parser_config->parse_datetime($1 . ' ' . $2);
                syslog(LOG_DEBUG, "%s: config saved: found ASA match '%s %s'", $hostnameport, $1, $2);
                last;
            } elsif ( $wartungstyp eq 'IOS' &&
                    $line =~ /^! NVRAM config last updated at (\d{2}:\d{2}:\d{2} \S+ \S{3} \S{3} \d{1,2} \d{4})( by \S+)?$/ ) {
                # Some (?) IOS XE based switches might not return this line, possibly when freshly reloaded.
                $time_dtf = $time_parser_config->parse_datetime($1);
                syslog(LOG_DEBUG, "%s: config saved: found IOS match '%s'", $hostnameport, $1);
                last;
            } elsif ( $wartungstyp eq 'NEX' &&
                    $line =~ /^!Startup config saved at: (\S{3} \S{3} \d{1,2} \d{2}:\d{2}:\d{2} \d{4})$/ ) {
                $time_dtf = $time_parser_config_nexus->parse_datetime($1);
                syslog(LOG_DEBUG, "%s: config saved: found NEX match '%s'", $hostnameport, $1);
                last;
            }
        }

        if ( defined($time_dtf) ) {
            $cfsavd = $time_formatter_db2ts->format_datetime($time_dtf);
            if ( defined($cfsavd) ) {
                syslog(LOG_DEBUG, "%s: config saved: using formatted date '%s'", $hostnameport, $cfsavd);
                # Actually write data.
                $sth_update_dcapf_cfsavd->execute($cfsavd, $hostnameport);
                if ( defined($dbh->errstr) ) {
                    syslog(LOG_NOTICE, "%s: config saved: SQL execution error: %s", $hostnameport, $dbh->errstr);
                }
            } else {
                syslog(LOG_NOTICE, "%s: config saved: could not format timestamp, invalid time zone?", $hostnameport);
            }
        } else {
            if ( defined($cfsavd_flash) ) {
                syslog(LOG_NOTICE, "%s: config saved: could not extract timestamp, using stamp from flash mem", $hostnameport);
                $cfsavd_flash = $cfsavd_flash;
            } else {
                syslog(LOG_NOTICE, "%s: config saved: could not extract timestamp, nor derive it from flash mem", $hostnameport);
            }
        }

        # --------------------------

        # Handle CVS/git stuff: Save configuration to text file.
        if ( $do_scm == 1 ) {
            $scmdestfile = sprintf("%s/%s", $scmtmp, $hostnameport);
            syslog(LOG_DEBUG, "%s: SCM: writing config to file '%s'", $hostnameport, $scmdestfile);

            # Handle new files: Must add if not existent prior to open-for-writing.
            if ( -e $scmdestfile ) {
                $do_scm_add = 0;
            } else {
                $do_scm_add = 1;
            }

            open($fh, ">", $scmdestfile);
            if ( $fh ) {
                foreach $line (@show_config) {
                    if ( $line =~ /^: Written by \S+ at / ||
                         $line =~ /^Cryptochecksum:/ ||
                         $line =~ /^! NVRAM config last updated at / ||
                         $line =~ /^! Last configuration change at / ||
                         $line =~ /^!Time: / ) {
                        syslog(LOG_DEBUG, "%s: SCM: skip unwanted line: '%s'", $hostnameport, $line);
                    } else {
                        # *DO NOT* use a comma to separate the file handle from the content-holding variable.
                        # Perl takes that as "print $fh and afterwards $before" instead of "print $before into filehandle $fh!
                        print($fh $line . "\n");
                    }
                }

                close($fh);

                # Need to add new files prior to committing.
                if ( $do_scm_add == 1 && $use_git == 0 ) {
                    $retval = system('cd ' . $scmtmp . ' && cvs -Q add ' . $hostnameport);
                } elsif ( $use_git == 1 ) {
                    $retval = system('cd ' . $scmtmp . ' && git add ' . $hostnameport);
                }
                $retval = ($retval >> 8);
                if ( $retval != 0 ) {
                    syslog(LOG_NOTICE, "%s: SCM: error %d while adding '%s', continuing anyway",
                        $hostnameport, $retval, $scmdestfile);
                }
            } else {
                syslog(LOG_NOTICE, "%s: SCM: could not open destination file '%s' for writing, skipping update",
                    $hostnameport, $scmdestfile);
            }
        }
    } else {
        syslog(LOG_WARNING, "%s: config: expect error %s encountered while trying '%s', skipping host",
            $hostnameport, $err, $show_config_command);
        # Usually this means we've lost the connection to the device and is always fatal => Skip host.
        # Note: this is the global skip if expect for extracting config goes wrong.
        $cnh->soft_close();
        $dbh->do("rollback");
        next;
    }

    # ----------------------------------------------------------------------

    # Parse IOS running config change timestamp. We're issuing "show run" for that purpose.
    if ( $wartungstyp eq 'IOS' ) {
        syslog(LOG_DEBUG, "%s: config changed (IOS): looking for timestamp lines in 'show running-config'", $hostnameport);
        $cnh->send("show running-config\n");

        ($pat, $err, $match, $before, $after) = $cnh->expect(5, '-re', $prompt_re);
        if ( ! defined($err) ) {
            # Filter nasty (un)printables.
            $before =~ tr/\000-\010|\013-\037|\177-\377//d;
            @show_config = split("\n", $before);

            # Config usually ends with a fixed string, so we can check if the obtained configuration is complete.
            if ( $show_config[-1] ne "end" ) {
                syslog(LOG_NOTICE, "%s: config changed (IOS): unexpected end of running-config: '%s', skipping timestamp handling",
                    $hostnameport, $show_config[-1]);
                next;
            } else {
                # Look for timestamp lines.
                foreach $line (@show_config) {
                    if ( $line =~ /^! Last configuration change at (\d{2}:\d{2}:\d{2} \S+ \S{3} \S{3} \d{1,2} \d{4})( by \S+)?$/ ) {
                        $time_dtf = $time_parser_config->parse_datetime($1);
                        if ( defined($time_dtf) ) {
                            $cfupdt = $time_formatter_db2ts->format_datetime($time_dtf);
                            syslog(LOG_DEBUG, "%s: config changed (IOS): using formatted date '%s'", $hostnameport, $cfupdt);
                        } else {
                            syslog(LOG_INFO, "%s: config changed (IOS): could not format timestamp, invalid time zone?",
                                $hostnameport);
                        }
                    } elsif ( $line =~ /^! No configuration change since last restart$/ ) {
                        # Only valid for classic IOS routers.
                        $found__no_config_chance_since_restart = 1;
                    } elsif ( $line =~ /^! NVRAM config last updated at/ ) {
                        $found__cfgsavd_in_running_cfg = 1;
                    }
                }

                # Indicators for an IOS or IOS XE device which has been reloaded with no configuration updates happening since.
                # We need this later when determining missed "write mem" of devices.
                # Note: This seems to be a more reliable way to find such devices. Determining if a reload happened just by looking
                #       at cfupdt > cfsavd && cfupdt > reloaded proves to be unreliable due to time needed to parse the startup
                #       config into the running config.
                if ( $found__no_config_chance_since_restart == 1 || $found__cfgsavd_in_running_cfg == 0 ) {
                    $just_reloaded = 1;
                    $cfupdt = $cfsavd;
                    syslog(LOG_DEBUG,
                        "%s: config changed (IOS): device seems freshly reloaded (%d, %d), using saved configuration stamp '%s'",
                            $hostnameport, $found__no_config_chance_since_restart, $found__cfgsavd_in_running_cfg, $cfupdt);
                } else {
                    $just_reloaded = 0;
                }
            }
        } else {
            syslog(LOG_WARNING,
                "%s: config changed (IOS): expect error %s encountered while trying 'show running-config', skipping host",
                    $hostnameport, $err);
            # Usually this means we've lost the connection to the device and is always fatal => Skip host.
            $cnh->soft_close();
            $dbh->do("rollback");
            next;
        }
    } elsif ( $wartungstyp eq 'ASA' ) {
        # Dorkily, ASA shows the last configuration change not in show run, but in show version.
        syslog(LOG_DEBUG, "%s: config changed (ASA): looking for timestamp line in 'show version'", $hostnameport);

        foreach $line (@show_version) {
            # Remove CR line by line for parsing into the database.
            $line =~ tr/\015//d;

            # Extract config changed timestamp.
            if ( $line =~ /^Configuration last modified by (.+) at (\d{2}:\d{2}:\d{2})\.\d+ (\S+ \S{3} \S{3} \d{1,2} \d{4})$/ ) {
                $time_dtf = $time_parser_config->parse_datetime($2 . ' ' .  $3);
                if ( defined($time_dtf) ) {
                    $cfupdt = $time_formatter_db2ts->format_datetime($time_dtf);
                    syslog(LOG_DEBUG, "%s: config changed (ASA): using formatted date '%s'", $hostnameport, $cfupdt);
                } else {
                    syslog(LOG_INFO, "%s: config changed (ASA): could not format timestamp, invalid time zone?", $hostnameport);
                }
            }
        }

        # Rebooted ASAs have no cfupdt if no config change after reload.
        if ( ! defined($cfupdt) ) {
            $just_reloaded = 1;
            $cfupdt = $cfsavd;
            syslog(LOG_DEBUG, "%s: config changed (ASA): device seems freshly reloaded, using saved configuration stamp '%s'",
                $hostnameport, $cfupdt);
        } else {
            $just_reloaded = 0;
        }
    }

    # Actually insert data.
    if ( $wartungstyp eq 'ASA' || $wartungstyp eq 'IOS' ) {
        if ( defined($cfupdt) ) {
            $sth_update_dcapf_cfupdt_justrld->execute($just_reloaded, $cfupdt, $hostnameport);
            if ( defined($dbh->errstr) ) {
                syslog(LOG_NOTICE, "%s: config changed (common): SQL execution error: %s", $hostnameport, $dbh->errstr);
            }
        } else {
            syslog(LOG_NOTICE, "%s: config changed (common): could not extract timestamp, nor derive it from startup-config",
                $hostnameport);
        }
    }

    # ----------------------------------------------------------------------

    # Alert if someone might have forgotten to write the running config back to the startup config.
    if ( $wartungstyp eq 'IOS' && defined($cfupdt) && defined($cfsavd) ) {
        if ( $cfupdt gt $cfsavd ) {
            syslog(LOG_INFO, "%s: running-config timestamp is newer than startup-config, forgot to save config with wr?",
                $hostnameport);
        }
    }

    # ----------------------------------------------------------------------

    syslog(LOG_DEBUG, "%s: Host loop: close connection to device", $hostnameport);
    $cnh->send("exit\n");
    $cnh->soft_close();

    # ------------------------------

    # Set "empty" dcapf fields to NULL.
    if ( $do_setnull == 1 ) {
        syslog(LOG_DEBUG, "%s: DB: Set \"empty\" dcapf fields to NULL", $hostnameport);

        # Text fields.
        @setnull_fields = ('asa_dm_ver', 'asa_fover', 'confreg', 'rld$reason', 'romver', 'sysimg', 'uptime', 'vtp_domain',
            'vtp_mode', 'vtp_prune');
        foreach $setnull_field (@setnull_fields) {
            $dbh->do("UPDATE dcapf SET $setnull_field=NULL WHERE hostname='$hostnameport' AND $setnull_field IN ('', 'NULL')");
            if ( defined($dbh->errstr) ) {
                syslog(LOG_NOTICE, "%s: DB: SQL execution error for '%s' (text) in cleanup database: %s, skipping to next field",
                    $hostnameport, $setnull_field, $dbh->errstr);
            }
        }

        # Numeric fields.
        @setnull_fields = ('uptime_min', 'vtp_vers');
        foreach $setnull_field (@setnull_fields) {
            $dbh->do("UPDATE dcapf SET $setnull_field=NULL WHERE hostname='$hostnameport' AND $setnull_field=-1");
            if ( defined($dbh->errstr) ) {
                syslog(LOG_NOTICE, "%s: DB: SQL execution error for '%s' (numeric) in cleanup database: %s, skipping to next field",
                    $hostnameport, $setnull_field, $dbh->errstr);
            }
        }

        # Timestamp fields.
        @setnull_fields = ('cfsavd', 'cfupdt');
        foreach $setnull_field (@setnull_fields) {
            $dbh->do("UPDATE dcapf SET $setnull_field=NULL WHERE hostname='$hostnameport' AND \
                $setnull_field='0001-01-01-00.00.00.000000'");
            if ( defined($dbh->errstr) ) {
                syslog(LOG_NOTICE, "%s: DB: SQL execution error for '%s' (stamp1) in cleanup database: %s, skipping to next field",
                    $hostnameport, $setnull_field, $dbh->errstr);
            }
        }
    }

    # One global commit per host: If we've come this far, things have hopefully worked out fine.
    syslog(LOG_DEBUG, "%s: DB: Committing all changes", $hostnameport);
    $dbh->do("commit");
} # foreach hostname

syslog(LOG_DEBUG, "Host loop: ended, doing cleanup");

# ----------------------------------------------------------------------------------------------------------------------------------

if ( $do_scm == 1 ) {
    if ( $do_orphans == 1 ) {
        # Remove orphaned files from SCM also.
        syslog(LOG_DEBUG, "SCM: identify and delete orphaned files");

        # Obtain a file list.
        opendir($dirfh,  $scmtmp);
        @filelist = readdir($dirfh);
        closedir($dirfh);
        @filelist = sort(@filelist);

        foreach $file (@filelist) {
            if ( $file ne 'CVS' && $file ne '.git' && $file ne '.' && $file ne '..' ) {
                # Check database for this file.
                $sth_select_count_hostname_scm->execute($file);
                if ( defined($dbh->errstr) ) {
                    syslog(LOG_NOTICE, "SCM: SQL execution error for '%s' in cleanup orphans: %s, skipping file",
                        $file, $dbh->errstr);
                    next;
                } else {
                    ($num_entries) = $sth_select_count_hostname_scm->fetchrow;
                    if ( defined($dbh->errstr) ) {
                        syslog(LOG_NOTICE, "SCM: SQL fetch error for '%s' in cleanup orphans: %s, skipping file",
                            $file, $dbh->errstr);
                        next;
                    } else {
                        if ( $num_entries == 0 ) {
                            # Delete if no entry found in database. No error handler for unlink needed:
                            # - private repository checkout
                            # - file list from checkout
                            unlink($scmtmp . '/' . $file);
                            if ( $use_git == 0 ) {
                                $retval = system( 'cd ' . $scmtmp . ' && cvs -Q delete ' . $file);
                            } else {
                                $retval = system( 'cd ' . $scmtmp . ' && git rm -q ' . $file);
                            }
                            $retval = ($retval >> 8);
                            if ( $retval != 0 ) {
                                syslog(LOG_NOTICE, "SCM: error %d while deleting orphaned '%s', skipping file",
                                    $retval, $file);
                            }
                        }
                    }
                }
            }
        }
    }

    # ----------------------------------

    # Commit (all) changes, including added files from above.
    syslog(LOG_DEBUG, "SCM: committing changes");
    if ( $use_git == 0 ) {
        $retval = system( 'cd ' . $scmtmp . ' && cvs -Q commit -m "Automatic Cisco-Config-Backup"');
        $retval = ($retval >> 8);
        if ( $retval != 0 ) {
            syslog(LOG_INFO, "SCM: error %d while committing, continuing anyway", $retval);
        }
    } else {
       if ((system( 'cd ' . $scmtmp . ' && git diff --quiet --cached --exit-code >/dev/null 2>&1') >> 8) == 1) {
            $retval = system( 'cd ' . $scmtmp . ' && git commit -q -m "Automatic Cisco-Config-Backup" >/dev/null 2>&1');
            $retval = ($retval >> 8);
            if ( $retval != 0 ) {
                syslog(LOG_INFO, "SCM: error %d while committing, continuing anyway", $retval);
            } else {
                syslog(LOG_DEBUG, "SCM: push changes");
                $retval = system( 'cd ' . $scmtmp . ' && git push -q >/dev/null 2>&1');
                $retval = ($retval >> 8);
                if ( $retval == 0 ) {
                    syslog(LOG_DEBUG, "SCM: git push successful");
                } else {
                    syslog(LOG_INFO, "SCM: error %d while pushing, continuing anyway", $retval);
                }
            }
        } else {
            syslog(LOG_DEBUG, "SCM: No changes, nothing to commit");
        }
    }
}

# ------------------------------------------------------------------------------

# Delete orphaned entries from the database.
if ( $do_orphans == 1 ) {
    syslog(LOG_DEBUG, "DB: Delete orphaned data from auxiliary tables (no associated entry in hstpf)");
    @to_clean_pfs = ('cfgverpf', 'dcapf', 'invpf');
    foreach $to_clean_pf (@to_clean_pfs) {
        $dbh->do("DELETE FROM $to_clean_pf WHERE hostname NOT IN (SELECT hostname FROM hstpf)");
        if ( defined($dbh->errstr) ) {
            syslog(LOG_NOTICE, "DB: SQL execution error for '%s' in cleanup database: %s, skipping to next table",
                $to_clean_pf, $dbh->errstr);
        } else {
            $dbh->do("commit");
        }
    }
}

# ------------------------------------------------------------------------------
# Uncommited changes after this point will be rolled back implicitly.
# ------------------------------------------------------------------------------

# Further cleanup is handled by the END block implicitly.
END {
    # $scmtmp housekeeping is done automatically through tempdir( CLEANUP => 1 );

    if (defined($cnh) ) {
        $cnh->send("exit\n");
        $cnh->soft_close();
    }

    if ( $sth_select_hosts ) {
        $sth_select_hosts->finish;
    }
    if ( $sth_delete_invpf ) {
        $sth_delete_invpf->finish;
    }
    if ( $sth_insert_invpf ) {
        $sth_insert_invpf->finish;
    }
    if ( $sth_delete_dcapf ) {
        $sth_delete_dcapf->finish;
    }
    if ( $sth_insert_dcapf ) {
        $sth_insert_dcapf->finish;
    }
    if ( $sth_update_dcapf_cfsavd ) {
        $sth_update_dcapf_cfsavd->finish;
    }
    if ( $sth_update_dcapf_cfupdt_justrld ) {
        $sth_update_dcapf_cfupdt_justrld->finish;
    }
    if ( $sth_update_dcapf_setasafailover ) {
        $sth_update_dcapf_setasafailover->finish;
    }
    if ( $sth_update_dcapf_vtp ) {
        $sth_update_dcapf_vtp->finish;
    }
    if ( $sth_delete_cfgverpf ) {
        $sth_delete_cfgverpf->finish;
    }
    if ( $sth_insert_cfgverpf ) {
        $sth_insert_cfgverpf->finish;
    }
    if ( $sth_delete_acdcapf ) {
        $sth_delete_acdcapf->finish;
    }
    if ( $sth_insert_acdcapf ) {
        $sth_insert_acdcapf->finish;
    }
    if ( $sth_delete_vlanpf ) {
        $sth_delete_vlanpf->finish;
    }
    if ( $sth_insert_vlanpf ) {
        $sth_insert_vlanpf->finish;
    }
    if ( $sth_select_count_hostname_scm ) {
        $sth_select_count_hostname_scm->finish;
    }

    if ( $dbh ) {
        $dbh->disconnect;
    }

    syslog(LOG_INFO, "Done");

    closelog;
}

#--------------------------------------------------------------------------------------------------------------
# vim: tabstop=4 shiftwidth=4 autoindent colorcolumn=133 expandtab textwidth=132
# -EOF-
