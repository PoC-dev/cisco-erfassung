#!/usr/bin/perl -w

# This is to be manually incremented on each "publish".
my $versionstring = '2024-08-02.00';

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

# FIXME: Harmonize appearance of syslog output.

# ----------------------------------------------------------------------------------------------------------------------------------

# How to access the database
our $config;
require "/etc/cisco-config-backuprc"; # For safety reasons, this data is not in the script.
my $odbc_dsn  = $config->{'odbc_dsn'};
my $odbc_user = $config->{'odbc_user'};
my $odbc_pass = $config->{'odbc_pass'};

# Which source control managemnt tool to use.
my $cvsproject = $config->{'cvsproject'};
my $giturl = $config->{'giturl'};

# ----------------------------------------------------------------------------------------------------------------------------------

# General vars.
my ($cleanup, $cnh, $scmdestfile, $scmtmp, $dbh, $dirfh, $do_scm, $do_scm_add, $do_orphans, $do_setnull, $fh, $file, $hostname,
    $hostport, $inv_have_line_name, $inv_have_line_pid, $num_entries, $param, $retval, $setnull_field,
    $show_config_command, $showverfeature, $stamp_type, $sth_select_hosts, $test_db,  $tmpline, $time_dtf, $time_formatter,
    $time_parser, $to_clean_pf, $try_loop_string, $use_git, @beforeLinesArray, @cnh_parms, @errtyp, @filelist, @lines, @params,
    @setnull_fields, @show_config, @show_version, @time_tm, @to_clean_pfs, @try_loop_strings
);

my $errcount = 0;

# Matches a Cisco-CLI-Prompt, so Expect knows when the result of the sent command has been sent.
my $prompt_re = '^((?!<).)*[\#>]\s?$';

# Vars from hstpf.
my ($hostnameport, $conn_method, $username, $passwd, $enable, $wartungstyp);

# Vars from cfgverpf.
my ($lineno, $line);

# Vars from dcapf. Also see handler if $do_setnull == 1!
my ( $asa_dm_ver, $asa_fover, $cfsavd, $cfupdt, $confreg, $flash, $model, $ram, $reload_reason, $serno, $stamp,
    $sysimg, $uptime, $uptime_min, $version, $vtp_domain, $vtp_mode, $vtp_prune, $vtp_vers);

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
$retval = getopts("cdhnotv", \%options);

if ( $retval != 1 ) {
    printf(STDERR "Wrong parameter error. Wanna use git and forgot to give an URL?\n\n");
}

if ( defined($options{h}) || $retval != 1 ) {
    printf("Usage: cisco-erfassung(.pl) [options] device1 [device2 ...]\nOptions:
    -c: Suppress CVS/git functions
    -d: Enable debug mode
    -h: Show this help and exit
    -n: Suppress setting empty database fields to NULL
    -o: Suppress cleanup of orphaned database entries, and orphaned CVS/git files
    -t: Test database connection and exit
    -v: Show version and exit\n\n");
    printf("Note that logging is done almost entirely via syslog, facility user.\n");
    exit(0);
} elsif ( defined($options{v}) ) {
    printf('Version %s\n', $versionstring);
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

syslog(LOG_INFO, "Startup: our version is '%s'", $versionstring);

# Use git instead of default CVS?
if ( $do_scm == 1 ) {
    if ( defined($giturl) && ! defined($cvsproject) ) {
        $use_git = 1;
        syslog(LOG_DEBUG, "SCM: using git with URL '%s'", $giturl);
    } elsif ( ! defined($giturl) && defined($cvsproject) ) {
        $use_git = 0;
        syslog(LOG_DEBUG, "SCM: using cvs with project '%s'", $cvsproject);
    } else {
        syslog(LOG_ERR, "SCM: both cvsproject and giturl in configuration, this is invalid. Exit.");
        die;
    }
}

# ----------------------------------------------------------------------------------------------------------------------------------

# Now let the game begin!
if ( $test_db == 1 ) {
    printf("Connecting to database...\n");
}
syslog(LOG_DEBUG, "Init: Connecting to database");
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

# ------------------------------------------------------------------------------

# Prepare reusable SQL statements.
syslog(LOG_DEBUG, "Init: Preparing reusable SQL statements");
my $sth_delete_invpf = $dbh->prepare("DELETE FROM invpf WHERE hostname=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error in: %s", $dbh->errstr);
    die;
}
my $sth_insert_invpf = $dbh->prepare("INSERT INTO invpf (hostname, inv\$name, inv\$descr, inv\$pid, inv\$vid, inv\$serno) \
    VALUES (?, ?, ?, ?, ?, ?)");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error in: %s", $dbh->errstr);
    die;
}

my $sth_delete_dcapf = $dbh->prepare("DELETE FROM dcapf WHERE hostname=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error in: %s", $dbh->errstr);
    die;
}
my $sth_insert_dcapf = $dbh->prepare("INSERT INTO dcapf (confreg, flash, hostname, model, ram, serno, stamp, sysimg, uptime, \
    uptime_min, version, asa_dm_ver, rld\$reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error in: %s", $dbh->errstr);
    die;
}
my $sth_update_dcapf_cfsavd_cfupdt = $dbh->prepare("UPDATE dcapf SET cfsavd=?, cfupdt=? WHERE hostname=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error in: %s", $dbh->errstr);
    die;
}
my $sth_update_dcapf_cfsavd = $dbh->prepare("UPDATE dcapf SET cfsavd=? WHERE hostname=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error in: %s", $dbh->errstr);
    die;
}
my $sth_update_dcapf_setasafailover = $dbh->prepare("UPDATE dcapf SET asa_fover=? WHERE hostname=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error in: %s", $dbh->errstr);
    die;
}
my $sth_update_dcapf_vtp = $dbh->prepare("UPDATE dcapf SET vtp_domain=?, vtp_mode=?, vtp_vers=?, vtp_prune=? \
    WHERE hostname=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error in: %s", $dbh->errstr);
    die;
}

my $sth_delete_cfgverpf = $dbh->prepare("DELETE FROM cfgverpf WHERE hostname=? AND typ=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error in: %s", $dbh->errstr);
    die;
}
my $sth_insert_cfgverpf = $dbh->prepare("INSERT INTO cfgverpf (hostname, typ, lineno, line) VALUES (?, ?, ?, ?)");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error in: %s", $dbh->errstr);
    die;
}

my $sth_delete_acdcapf = $dbh->prepare("DELETE FROM acdcapf WHERE hostname=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error in: %s", $dbh->errstr);
    die;
}
my $sth_insert_acdcapf = $dbh->prepare("INSERT INTO acdcapf (hostname, ac_type, ac_ver) VALUES (?, ?, ?)");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error in: %s", $dbh->errstr);
    die;
}

my $sth_delete_vlanpf = $dbh->prepare("DELETE FROM vlanpf WHERE hostname=?");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error in: %s", $dbh->errstr);
    die;
}
my $sth_insert_vlanpf = $dbh->prepare("INSERT INTO vlanpf (hostname, descr, vlan) VALUES (?, ?, ?)");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error in: %s", $dbh->errstr);
    die;
}

my $sth_select_count_hostname_scm = $dbh->prepare("SELECT COUNT(hostname) FROM hstpf WHERE hostname=? FOR READ ONLY");
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "SQL preparation error in: %s", $dbh->errstr);
    die;
}


# Prepare reusable timestamp formatting.
$time_parser = DateTime::Format::Strptime->new(
    pattern => "%T %Z %a %b %d %Y",
);
$time_formatter = DateTime::Format::Strptime->new(
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
                syslog(LOG_DEBUG, "SCM: Real work dir is '%s'", $scmtmp);
            } else {
                syslog(LOG_NOTICE, "SCM: Unable to deduce local directory from git URL, skipping scm functions");
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
syslog(LOG_DEBUG, "Host loop: Prepare");
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
    syslog(LOG_ERR, "Host loop: SQL preparation error in: %s", $dbh->errstr);
    die;
}

$sth_select_hosts->execute();
if ( defined($dbh->errstr) ) {
    syslog(LOG_ERR, "Host loop: SQL execution error in: %s", $dbh->errstr);
    die;
}

# ------------------

# Loop thru hosts, query things, shove data around, shove into database.
while ( ($hostnameport, $conn_method, $username, $passwd, $enable, $wartungstyp) = $sth_select_hosts->fetchrow ) {
    if ( defined($dbh->errstr) ) {
        syslog(LOG_ERR, "Host loop: SQL fetch error in: %s", $dbh->errstr);
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
        syslog(LOG_DEBUG, "Host loop: Connect %s: port %d using %s, wartungstyp %s", $hostname, $hostport, $conn_method,
                $wartungstyp);
    } else {
        syslog(LOG_DEBUG, "Host loop: Connect %s: using %s, wartungstyp %s", $hostname, $conn_method, $wartungstyp);
    }


    # Clear call array for telnet/ssh by expect from stray entries of former run.
    @cnh_parms = ();

    # Connect and try to log in.
    if ( $conn_method eq "telnet" ) {
        push(@cnh_parms, $hostname);
        if ( $hostport ) {
            push(@cnh_parms, $hostport);
        }
        $cnh = Expect->spawn("/usr/bin/telnet", @cnh_parms);
        $cnh->log_stdout(0);
        $cnh->exp_internal(0);

        # FIXME: Handle (today extremely uncommon) case of telnet-login without user but only password: no aaa new model.

        ($pat, $err, $match, $before, $after) = $cnh->expect(10, 'Username:');
        $cnh->send($username . "\n");
        $cnh->expect(5, 'Password:');
        $cnh->send($passwd . "\n");
    } elsif ( $conn_method eq "ssh" ) {
        if ( $hostport ) {
            push(@cnh_parms, "-p " . $hostport);
        }
        push(@cnh_parms, $username . "@" . $hostname);
        $cnh = Expect->spawn("/usr/bin/ssh", @cnh_parms);
        $cnh->log_stdout(0);
        $cnh->exp_internal(0);

        # FIXME: Maybe do this in a loop until we have a defined $pat?
        ($pat, $err, $match, $before, $after) = $cnh->expect(30, '-re',
            '(\S+ )?[Pp]assword:',
            'Are you sure you want to continue connecting',
            '% Authorization failed\.');
        if ( ! defined($err) ) {
            if ( $pat eq 2 ) {
                $cnh->send("yes\n");
                $cnh->expect(10, '-re', '(\S+ )?[Pp]assword:');
            } elsif ( $pat eq 3 ) {
                syslog(LOG_WARNING, "%s: failed local authorization, skipping", $hostnameport);
                next;
            }
            # FIXME: How can we know if we (not) failed local authorization here? Blindly sending a password? Hmm.
            $cnh->send($passwd . "\n");
        }
    } else {
        syslog(LOG_WARNING, "%s: unknown connection method %s, skipping", $hostnameport, $conn_method);
        next;
    }

    # If we can't log in, skip further processing for that host.
    if ( $err ) {
        syslog(LOG_WARNING, "%s: expect error %s encountered when spawning %s, skipping", $hostnameport, $err, $conn_method);
        next;
    }

    # --------------------------------------------------------------------------

    # If we have a valid connection handle, continue talking to the device.
    if ( $cnh ) {
        # Clear vars from previous iteration.
        $asa_dm_ver = $asa_fover = $cfsavd = $cfupdt =  $confreg = $flash = $model = $ram = $reload_reason = $serno =
            $stamp = $sysimg = $uptime = $uptime_min = $version = $vtp_domain = $vtp_mode = $vtp_prune = $vtp_vers = $inv_name =
            $inv_descr = $inv_pid = $inv_vid = $inv_serno = $ac_type = $ac_ver = $vlan_descr = $vlan_no = undef;

        # Common I/O for both telnet and ssh.
        ($pat, $err, $match, $before, $after) = $cnh->expect(5,
            '-re', '^.*>\s?$',
            '-re', '^.*\#\s?$'
        );

        # Handle Connection timeouts properly?
        if ( ! defined($pat) ) {
            syslog(LOG_WARNING, "%s: timeout while waiting for command line prompt, skipping", $hostnameport);
            next;
        }

        # Handle enabling of the user.
        if ( $pat eq 1 ) {
            if ( $enable ) {
                $cnh->send("enable\n");
                $cnh->expect(5, '-re', '^\s*Password: \s?$');
                $cnh->send($enable . "\n");
            } else {
                syslog(LOG_WARNING, "%s: need to send 'enable' but enable password is not defined in database, skipping",
                    $hostnameport);
                $cnh->send("exit\n");
                $cnh->soft_close();
                next;
            }
        } else {
            # Just press return - altering send/expect is mandatory.
            $cnh->send("\n");
        }
        $cnh->expect(5, '-re', $prompt_re);


        # Switch off interactive pager.
        if ( $wartungstyp eq 'IOS' || $wartungstyp eq 'UBI' || $wartungstyp eq 'NEX' ) {
            $cnh->send("terminal length 0\n");
        } elsif ( $wartungstyp eq 'ASA' ) {
            $cnh->send("terminal pager 0\n");
        }
        $cnh->expect(5, '-re', $prompt_re);

        # ----------------------------------------------------------------------

        # Show Version and parse output of it.
        syslog(LOG_DEBUG, "%s: Handle 'show version'", $hostnameport);
        $cnh->send("show version\n");
        ($pat, $err, $match, $before, $after) = $cnh->expect(5, '-re', $prompt_re);

        if ( ! defined($err) ) {
            # Filter nasty (un)printables. Keep CR, so we have array entries for "empty" lines.
            $before =~ tr/\000-\010|\013-\014|\016-\037|\177-\377//d;

            # See if we can parse the content of $before (containing show version result).
            @show_version = split("\n", $before);
            foreach $line (@show_version) {
                # Remove CR only for parsing into the database.
                # FIXME: Harmonize this. We probably have this in too many places instead of one centralized.
                $line =~ tr/\015//d;

                # FIXME: How can we make these lines shorter to fit in 132 chars?
                if ( $wartungstyp eq 'IOS' ) {
                    if ( $line =~ /^(Cisco )?IOS(-XE)? (Software( \[\S+\])?,|\(tm\)) .* Software \((\S+)\), Version ([0-9A-Za-z\.\(\)]+)[,]? RELEASE SOFTWARE \(fc\d+\)\s*$/ ) {
                        $showverfeature = $5;
                        $version = $6;
                    } elsif ( $line =~ /^[Cc]isco\s+(\S+)\s+(\(.+\)\s+processor\s+)?(\(revision \S+\))?\s?+with\s+(\d+)K(\/(\d+)K)?\s+bytes\s+of\s+(physical )?memory\.\s*$/ ) {
                        $model = $1;
                        $ram = $4;
                        # Add iomem, if avail.
                        if ( $6 ) {
                            $ram = $ram + $6;
                        }
                        $ram = sprintf("%.0f", $ram / 1024);
                    } elsif ( $line =~ /^System image file is "(\S+)"(, booted via flash)?\s*$/ ) {
                        $sysimg = $1;
                    } elsif ( $line =~ /^(Processor board ID|Motherboard serial number:) (\w+)( \(\w+\))?(, with hardware revision \w+)?\s*$/ ) {
                        $serno = $2;
                    } elsif ( $line =~ /^(\d+)K bytes of Flash at flash:\.\s*$/
                            || $line =~ /^(\d+)K bytes of processor board System flash \(Read ONLY\)\s*$/
                            || $line =~ /^(\d+)K bytes (of (processor board \w+ flash|ATA (System )?CompactFlash) (\d )?\((Read\/Write|Intel Strataflash)\)|system flash allocated)\s*$/ ) {
                        $flash = sprintf("%.0f", $1 / 1024);
                    } elsif ( $line =~ /^\S+ uptime is (.+)\s*$/ ) {
                        $uptime = $1;
                    } elsif ( $line =~ /^System returned to ROM by (.+)\s*$/ ) {
                        $reload_reason = $1;
                    } elsif ( $line =~ /^System restarted by (.+) at .*$/ ) {
                        # IOS 11
                        $reload_reason = $1;
                    } elsif ( $line =~ /^Configuration register is (\w+)( \(will be \w+ at next reload\))?\s*$/ ) {
                        $confreg = $1;
                    }
                } elsif ( $wartungstyp eq 'ASA' ) {
                    if ( $line =~ /^Cisco Adaptive Security Appliance Software Version (\S+)\s*$/ ) {
                        $version = $1;
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

            syslog(LOG_DEBUG, "%s: Show version: Updating raw data in database", $hostnameport);
            $sth_delete_cfgverpf->execute($hostnameport, 'ver');
            if ( defined($dbh->errstr) ) {
                syslog(LOG_NOTICE, "%s: Show version: SQL execution error in: %s", $hostnameport, $dbh->errstr);
                $dbh->do("rollback");
            } else {
                # Delete first line 'show version'.
                splice(@show_version, 0, 1);

                $lineno = 0;
                foreach $line (@show_version) {
                    # Remove CR only for parsing into the database.
                    $line =~ tr/\015//d;

                    # Gracefully handle empty lines.
                    if ( length($line) lt 132 ) {
                        @lines = ( $line );
                    } else {
                        @lines = ( $line =~ m/.{1,131}/g );
                    }
                    foreach $tmpline (@lines) {
                        $lineno++;
                        $sth_insert_cfgverpf->execute($hostnameport, 'ver', $lineno, $tmpline);

                        # Terminate inner loop if there was an error.
                        if ( defined($dbh->errstr) ) {
                            syslog(LOG_NOTICE, "%s: show version: SQL execution error in: %s", $hostnameport, $dbh->errstr);
                            $errcount++;
                            last;
                        }
                    }

                    # Terminate outer loop if there was an error.
                    if ( $errcount > 0 ) {
                        last;
                    }
                }

                # Terminate host loop if there was an error.
                if ( $errcount > 0 ) {
                    syslog(LOG_ERR, "%s: show version: skipping host because of earlier errors", $hostnameport);
                    $dbh->do("rollback");
                    last;
                }
            }
        } else {
            syslog(LOG_WARNING, "%s: show version: expect error %s encountered while trying command, skipping host",
                    $hostnameport, $err);
            next;
        }

        # ------------------------------

        # Check if we still don't know the size of flash mem - happens with some switches and other oddities.
        # Need to try harder in this case.
        if ( ! defined($flash) ) {
            syslog(LOG_DEBUG, "%s: flash: no flash information derived from 'show version', trying flash directory commands",
                $hostnameport);
            if ( $wartungstyp eq 'IOS' ) {
                # Some newer devices insist on flash: (with colon) here. Do that in a loop and jump out if we have what we want.
                @try_loop_strings = ('show flash', 'show flash:', 'show bootflash:');
                foreach $try_loop_string (@try_loop_strings) {
                    $cnh->send($try_loop_string . "\n");
                    ($pat, $err, $match, $before, $after) = $cnh->expect(5, '-re', $prompt_re);

                    if ( ! defined($err) ) {
                        # Filter nasty (un)printables.
                        # Note: We have no logic for information input spanning multiple lines. Thus we can filter out CR.
                        $before =~ tr/\000-\010|\013-\037|\177-\377//d;

                        @beforeLinesArray = split("\n", $before);
                        foreach $line (@beforeLinesArray) {
                            # Again, different devices have different output.
                            if ( $line =~ /^(\d+) bytes total \(\d+ bytes free\)\s*$/ ) {
                                $flash = sprintf("%.0f", $1 / 1024 / 1024);
                            } elsif ( $line =~ /^(\d+) bytes available \((\d+) bytes used\)\s*$/ ) {
                                if ( defined($1) && defined($2) ) {
                                    $flash = sprintf("%.0f", ($1 + $2) / 1024 / 1024);
                                } else {
                                    syslog(LOG_NOTICE, "%s: flash: size NOT read from %s, because it is malformed. (%s, %s)",
                                        $hostnameport, $try_loop_string, $1, $2);
                                }
                            }
                            if ( $flash ) {
                                last;
                            }
                        }
                    } else {
                        syslog(LOG_NOTICE, "%s: flash: expect error %s encountered while trying '%s', skipping",
                            $hostnameport, $err, $try_loop_string);
                    }
                }
            } elsif ( $wartungstyp eq 'ASA' ) {
                $cnh->send("dir flash:\n");
                ($pat, $err, $match, $before, $after) = $cnh->expect(5, '-re', $prompt_re);

                if ( ! defined($err) ) {
                    # Filter nasty (un)printables.
                    # Note: We have no logic for information input spanning multiple lines. Thus we can filter out CR.
                    $before =~ tr/\000-\010|\013-\037|\177-\377//d;

                    @beforeLinesArray = split("\n", $before);
                    foreach $line (@beforeLinesArray) {
                        if ( $line =~ /^(\d+) bytes total \(\d+ bytes free\/\d+% free\)\s*$/ ) {
                            $flash = sprintf("%.0f", $1 / 1024 / 1024);
                            last;
                        }
                    }
                } else {
                    syslog(LOG_NOTICE, "%s: flash: expect error %s encountered while trying 'dir flash:', skipping",
                            $hostnameport, $err);
                }
            }
        }

        # ----------------------------------------------------------------------

        # Handle show inventory.

        # Why is this in the middle of handling 'show version'? Because of ASA:
        #  The serial number in ASA 'show version' (for licensing) is not the same as printed on the chassis,
        #   which is required for service contracts. Thus we need to deduce the HW serial after parsing of
        #   'show_version' output, put before inserting that data into dcapf.
        # In a way this is thus part of 'show version' - for ASAs, with additional benefits to be seen in invpf.

        syslog(LOG_DEBUG, "%s: Handle 'show inventory'", $hostnameport);
        $cnh->send("show inventory\n");
        ($pat, $err, $match, $before, $after) = $cnh->expect(5, '-re', $prompt_re);

        if ( ! defined($err) ) {
            # Clean table from old entries.
            $sth_delete_invpf->execute($hostnameport);
            if ( defined($dbh->errstr) ) {
                syslog(LOG_NOTICE, "%s: show inventory: SQL execution error in: %s", $hostnameport, $dbh->errstr);
                $dbh->do("rollback");
            } else {
                # Set defaults for our parser helpers.
                $inv_have_line_name = $inv_have_line_pid = 0;

                # Filter nasty (un)printables. Keep CR, so we have array entries for "empty" lines.
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
                            if ( $wartungstyp eq 'ASA' ) {
                                $serno = $inv_serno;
                            }

                            $sth_insert_invpf->execute($hostnameport, $inv_name, $inv_descr, $inv_pid, $inv_vid, $inv_serno);
                            if ( defined($dbh->errstr) ) {
                                syslog(LOG_NOTICE, "%s: show inventory: SQL execution error in: %s", $hostnameport, $dbh->errstr);
                                $dbh->do("rollback");
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
                        syslog(LOG_NOTICE, "%s: show inventory: doesn't understand command: %s", $hostnameport);
                        last;
                    }
                }
            }
        } else {
            syslog(LOG_NOTICE, "%s: show inventory: expect error %s encountered while trying command, skipping",
                    $hostnameport, $err);
        }

        # ----------------------------------------------------------------------

        # Calculate Uptime in Minutes, for our statistics.
        $uptime_min = 0;
        if ( defined($uptime) ) {
            syslog(LOG_DEBUG, "%s: Handle uptime calculation", $hostnameport);
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
            syslog(LOG_NOTICE, "%s: uptime: has not been extracted, calculation of uptime_min impossible, skipping", $hostnameport);
        }

        # ----------------------------------------------------------------------

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

        if ( ! defined($uptime) ) {
            push(@errtyp, 'uptime');
            $errcount++;
        }

        # ----------------------------------------------------------------------

        # Actually insert.
        if ( $errcount == 0 ) {
            syslog(LOG_DEBUG, "%s: show version: handle inserting of collected informational data (dcapf)", $hostnameport);

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
            if ( ! defined($sysimg) ) {
                $sysimg = 'NULL';
            }
            if ( ! defined($uptime) ) {
                $uptime = 'NULL';
            }


            # Delete old entry in database.
            $sth_delete_dcapf->execute($hostnameport);
            if ( defined($dbh->errstr) ) {
                syslog(LOG_NOTICE, "%s: show version (delete): SQL execution error in: %s, skipping host",
                    $hostnameport, $dbh->errstr);
                $dbh->do("rollback");
                next;
            } else {
                # Prepare timestamps for, well, timestamps. In the database, that is.
                @time_tm = localtime();
                $stamp = strftime('%Y-%m-%d-%H.%M.%S.000000', @time_tm);

                # Deletion succeeded, continue with insert.
                $sth_insert_dcapf->execute($confreg, $flash, $hostnameport, $model, $ram, $serno, $stamp, $sysimg, $uptime,
                    $uptime_min, $version, $asa_dm_ver, $reload_reason);
                if ( defined($dbh->errstr) ) {
                    syslog(LOG_NOTICE, "%s: show version (insert): SQL execution error in: %s, skipping host",
                        $hostnameport, $dbh->errstr);
                    $dbh->do("rollback");
                    next;
                }
            }
        } else {
            syslog(LOG_WARNING, "%s: show version: Collected data lacks mandatory fields %s; skipping 'show version' handling",
                $hostnameport, join(', ', @errtyp));
            $errcount = 0;
        }

        # ----------------------------------------------------------------------

        # For wholesome recovery, we need information about current Vlan-Configuration.
        if ( $wartungstyp eq 'IOS' ) {
            syslog(LOG_DEBUG, "%s: Retrieving VTP configuration", $hostnameport);

            $cnh->send("show vtp status\n");
            ($pat, $err, $match, $before, $after) = $cnh->expect(5, '-re', $prompt_re);

            if ( ! defined($err) ) {
                # Filter nasty (un)printables.
                # Note: We have no logic for information input spanning multiple lines. Thus we can filter out CR.
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
                        syslog(LOG_NOTICE, "%s: VTP: doesn't understand 'show vtp status': %s", $hostnameport);
                        $err = 1;
                        last;
                    }
                }

                # Write found data into database.
                $sth_update_dcapf_vtp->execute($vtp_domain, $vtp_mode, $vtp_vers, $vtp_prune, $hostnameport);
                if ( defined($dbh->errstr) ) {
                    syslog(LOG_NOTICE, "%s: VTP: SQL execution error in: %s", $hostnameport, $dbh->errstr);
                    $dbh->do("rollback");
                }

                # Don't carry over to the next host loop.
                $vtp_vers = $vtp_domain = $vtp_prune = $vtp_mode = undef;
            } else {
                syslog(LOG_NOTICE, "%s: VTP: expect error %s encountered while trying 'show vtp status', skipping",
                    $hostnameport, $err);
            }
        }

        # ----------------------------------------------------------------------

        if ( $wartungstyp eq 'IOS' ) {
            syslog(LOG_DEBUG, "%s: Retrieving Vlan configuration", $hostnameport);

            # Delete old entry in database.
            $sth_delete_vlanpf->execute($hostnameport);
            if ( defined($dbh->errstr) ) {
                syslog(LOG_NOTICE, "%s: Vlan: SQL execution error in: %s", $hostnameport, $dbh->errstr);
                $dbh->do("rollback");
            } else {
                @try_loop_strings = ('show vlan', 'show vlan-switch');
                foreach $try_loop_string (@try_loop_strings) {
                    $cnh->send($try_loop_string . "\n");
                    ($pat, $err, $match, $before, $after) = $cnh->expect(5, '-re', $prompt_re);

                    if ( ! defined($err) ) {
                        # Filter nasty (un)printables.
                        # Note: We have no logic for information input spanning multiple lines. Thus we can filter out CR.
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
                                        syslog(LOG_NOTICE, "%s: Vlan: SQL execution error in: %s", $hostnameport, $dbh->errstr);
                                        $dbh->do("rollback");
                                        last;
                                    }
                                }
                            } elsif ( $line =~ /^% Invalid input detected at '^' marker\.$/ ) {
                                syslog(LOG_INFO, "%s: Vlan: soesn't understand '%s'", $hostnameport, $try_loop_string);
                                next;
                            }
                        }
                    } else {
                        syslog(LOG_NOTICE, "%s: Vlan: expect error %s encountered while trying '%s', skipping",
                            $hostnameport, $err, $try_loop_string);
                    }
                }
                # Don't carry over to the next host loop.
                $vlan_descr = $vlan_no = undef;
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
        syslog(LOG_DEBUG, "%s: Handle '%s'", $hostnameport, $show_config_command);
        $cnh->send($show_config_command . "\n");

        ($pat, $err, $match, $before, $after) = $cnh->expect(5, '-re', $prompt_re);
        if ( ! defined($err) ) {
            # Filter nasty (un)printables.
            # Note: We have no logic for information input spanning multiple lines. Thus we can filter out CR.
            $before =~ tr/\000-\010|\013-\037|\177-\377//d;
            @show_config = split("\n", $before);

            # --------------------------

            # Config usually ends with a fixed string, so we can check if the obtained configuration is complete.
            if ( ($wartungstyp eq 'IOS' || $wartungstyp eq 'UBI') && $show_config[-1] ne "end" ) {
                syslog(LOG_NOTICE, "%s: Config: Unexpected end of startup-config: '%s', skipping configuration handling",
                    $hostnameport, $show_config[-1]);
                next;
            } elsif ( $wartungstyp eq 'ASA' && $show_config[-1] ne ": end" ) {
                syslog(LOG_NOTICE, "%s: Config: Unexpected end of running-config: '%s', skipping configuration handling",
                    $hostnameport, $show_config[-1]);
                next;
            } elsif ( $wartungstyp eq 'NEX' && scalar @show_config < 12 ) {
                # FIXME: 12 might seem an arbitrary number, but there is no designated config end. Better ideas welcome!
                syslog(LOG_NOTICE, "%s: Config: Configuration has less than 12 lines, and ends with '%s', skipping configuration handling",
                    $hostnameport, $show_config[-1]);
                next;
            }

            # --------------------------

            # Save configuration into database. Therefore, delete previous database entries, and rewrite.
            syslog(LOG_DEBUG, "%s: config: save configuration to database", $hostnameport);
            $errcount = 0;
            $sth_delete_cfgverpf->execute($hostnameport, 'cfg');
            if ( defined($dbh->errstr) ) {
                syslog(LOG_NOTICE, "%s: config: SQL execution error in: %s", $hostnameport, $dbh->errstr);
                $dbh->do("rollback");
            } else {
                $lineno = 0;
                foreach $line (@show_config) {
                    # Remove CR only for parsing into the database.
                    $line =~ tr/\015//d;

                    # Gracefully handle empty lines.
                    if ( length($line) lt 132 ) {
                        @lines = ( $line );
                    } else {
                        @lines = ( $line =~ m/.{1,131}/g );
                    }
                    foreach $tmpline (@lines) {
                        $lineno++;
                        $sth_insert_cfgverpf->execute($hostnameport, 'cfg', $lineno, $tmpline);

                        # Terminate inner loop if there was an error.
                        if ( defined($dbh->errstr) ) {
                            syslog(LOG_NOTICE, "%s: config: SQL execution error in: %s", $hostnameport, $dbh->errstr);
                            $errcount++;
                            last;
                        }
                    }

                    # Terminate outer loop if there was an error.
                    if ( $errcount > 0 ) {
                        last;
                    }
                }

                # Terminate host loop if there was an error.
                if ( $errcount > 0 ) {
                    syslog(LOG_ERR, "%s: config: skipping host because of earlier errors", $hostnameport);
                    $dbh->do("rollback");
                    last;
                } else {
                    syslog(LOG_DEBUG, "%s: config: saved %d lines of  configuration to database", $hostnameport, $lineno);
                }
            }
            @lines = ();

            # --------------------------

            # List anyconnect versions. This has to be parsed from the configuration, so the actually used packages are listed!
            syslog(LOG_DEBUG, "%s: Look for Cisco Anyconnect in configuration data", $hostnameport);
            $sth_delete_acdcapf->execute($hostnameport);
            if ( defined($dbh->errstr) ) {
                syslog(LOG_NOTICE, "%s: Anyconnect: SQL execution error in: %s", $hostnameport, $dbh->errstr);
                $dbh->do("rollback");
            } else {
                foreach $line (@show_config) {
                    # Remove CR only for parsing into the database.
                    $line =~ tr/\015//d;

                    if ( $wartungstyp eq 'IOS' &&
                            $line =~ /^crypto vpn anyconnect flash:\/webvpn\/anyconnect-(\S+)-([\d.]+)(-webdeploy)?-k9\.pkg sequence \d+$/ ) {
                        syslog(LOG_DEBUG, "%s: Anyconnect: Found '%s'", $hostnameport, $line);
                        if ( defined($1) && defined($2) ) {
                            $ac_type = $1;
                            $ac_ver = $2;
                        }
                    } elsif ( $wartungstyp eq 'ASA' &&
                            $line =~ /^\s*anyconnect image disk0:\/anyconnect-(\S+)-([\d.]+)(-webdeploy)?-k9\.pkg \d+$/ ) {
                        syslog(LOG_DEBUG, "%s: Anyconnect: Found '%s'", $hostnameport, $line);
                        if ( defined($1) && defined($2) ) {
                            $ac_type = $1;
                            $ac_ver = $2;
                        }
                    }

                    if ( defined($ac_type) && defined($ac_ver) ) {
                        syslog(LOG_DEBUG, "%s: Anyconnect: Insert version '%s' for type '%s'", $hostnameport, $ac_ver, $ac_type);
                        $sth_insert_acdcapf->execute($hostnameport, $ac_type, $ac_ver);
                        if ( defined($dbh->errstr) ) {
                            syslog(LOG_NOTICE, "%s: Anyconnect: SQL execution error in: %s", $hostnameport, $dbh->errstr);
                            $dbh->do("rollback");
                        }
                    }

                    # Don't carry over to the next loop iteration.
                    $ac_type = $ac_ver = undef;
                }
            }

            # --------------------------

            # Parse ASA Timestamp into cfsavd. Uses existing configuration data in @show_config.
            if ( $wartungstyp eq 'ASA' ) {
                syslog(LOG_DEBUG, "%s: Gather config timestamps from ASA config", $hostnameport);

                # Look for timestamp lines.
                foreach $line (@show_config) {
                    # Remove CR only for parsing into the database.
                    $line =~ tr/\015//d;

                    if ( $line =~ /^: Written by \S+ at (\d{2}:\d{2}:\d{2})\.\d{3} (\S+ \S{3} \S{3} \d{1,2} \d{4})$/ ) {
                        $time_dtf = $time_parser->parse_datetime($1 . ' ' . $2);
                        $cfsavd = $time_formatter->format_datetime($time_dtf);
                        syslog(LOG_DEBUG, "%s: Gather config timestamps from ASA config found '%s'", $hostnameport, $cfsavd);

                        # Actually write data.
                        $sth_update_dcapf_cfsavd->execute($cfsavd, $hostnameport);
                        if ( defined($dbh->errstr) ) {
                            syslog(LOG_NOTICE, "%s: Gather config timestamps from ASA config: SQL execution error in: %s",
                                $hostnameport, $dbh->errstr);
                        }

                        # Spare some loop iterations.
                        last;
                    }
                }
            }

            # --------------------------

            # Handle CVS/git stuff: Save configuration to text file.
            if ( $do_scm == 1 ) {
                $scmdestfile = sprintf("%s/%s", $scmtmp, $hostnameport);
                syslog(LOG_DEBUG, "%s: SCM: Handling configuration update in file '%s'", $hostnameport, $scmdestfile);

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
                        syslog(LOG_NOTICE, "SCM: error %d while adding, continuing anyway", $retval);
                    }

                    # Prepare timestamp for, well, a timestamp. In the database, that is.
                    @time_tm = localtime();
                    $stamp = strftime('%Y-%m-%d-%H.%M.%S.000000', @time_tm);

                    # Has config changed?
                    if ( $use_git == 0 ) {
                        $retval = system('cd ' . $scmtmp . ' && cvs -Q diff ' . $hostnameport . ' >/dev/null 2>&1');
                    } else {
                        $retval = system('cd ' . $scmtmp . ' && git diff --quiet ' . $hostnameport);
                    }
                    $retval = ($retval >> 8);
                    syslog(LOG_DEBUG, "%s: SCM: diff return value: %s", $hostnameport, $retval);
                } else {
                    syslog(LOG_NOTICE, "%s: SCM: Could not open destination file '%s' for writing, skipping update",
                        $hostnameport, $scmdestfile);
                }
            }
        } else {
            syslog(LOG_NOTICE, "%s: config: expect error %s encountered while trying '%s', skipping",
                $hostnameport, $err, $show_config_command);
        }

        # ----------------------------------------------------------------------

        # Handle show failover - for ASA only.
        if ( $wartungstyp eq 'ASA' ) {
            syslog(LOG_DEBUG, "%s: Check ASA failover", $hostnameport);

            $cnh->send("show failover\n");
            ($pat, $err, $match, $before, $after) = $cnh->expect(5, '-re', $prompt_re);

            if ( ! defined($err) ) {
                # Filter nasty (un)printables.
                $before =~ tr/\000-\010|\013-\037|\177-\377//d;

                # Loop through lines.
                @beforeLinesArray = split("\n", $before);
                foreach $line (@beforeLinesArray) {
                    # Remove CR only for parsing into the database.
                    $line =~ tr/\015//d;

                    if ( $line =~ /^Failover (On|Off)\s*$/ ) {
                        if ( $1 eq "On" ) {
                            $sth_update_dcapf_setasafailover->execute('1', $hostnameport);
                        } elsif ( $1 eq "Off" ) {
                            $sth_update_dcapf_setasafailover->execute('0', $hostnameport);
                        }
                        if ( defined($dbh->errstr) ) {
                            syslog(LOG_NOTICE, "%s: ASA failover: SQL execution error in: %s", $hostnameport, $dbh->errstr);
                        }
                        last;
                    }
                }
            } else {
                syslog(LOG_NOTICE, "%s: ASA failover: expect error %s encountered while trying 'show failover'",
                        $hostnameport, $err);
            }
        }

        # ----------------------------------------------------------------------

        # Parse IOS Timestamps into cfupdt, cfsavd.
        if ( $wartungstyp eq 'IOS' ) {
            syslog(LOG_DEBUG, "%s: Gather config timestamps with 'show running-config' on IOS", $hostnameport);
            $cnh->send("show running-config\n");

            ($pat, $err, $match, $before, $after) = $cnh->expect(5, '-re', $prompt_re);
            if ( ! defined($err) ) {
                # Filter nasty (un)printables.
                # Note: We have no logic for information input spanning multiple lines. Thus we can filter out CR.
                $before =~ tr/\000-\010|\013-\037|\177-\377//d;
                @show_config = split("\n", $before);

                # Config usually ends with a fixed string, so we can check if the obtained configuration is complete.
                if ( $show_config[-1] ne "end" ) {
                    syslog(LOG_NOTICE, "%s: config timestamps: Unexpected end of running-config: '%s', skipping timestamp handling",
                        $hostnameport, $show_config[-1]);
                    next;
                }

                # Look for timestamp lines.
                foreach $line (@show_config) {
                    if ( $line =~ /^! Last configuration change at (\d{2}:\d{2}:\d{2} \S+ \S{3} \S{3} \d{1,2} \d{4}) by \S+$/ ) {
                        $stamp_type = 'run';
                    } elsif ( $line =~ /^! NVRAM config last updated at (\d{2}:\d{2}:\d{2} \S+ \S{3} \S{3} \d{1,2} \d{4}) by \S+$/ ) {
                        $stamp_type = 'sav';
                    } else {
                        undef($stamp_type);
                    }

                    # Safety checks and fill final variables.
                    if ( defined ($stamp_type) && defined ($1) ) {
                        $time_dtf = $time_parser->parse_datetime($1);

                        if ( $stamp_type eq 'run' ) {
                            $cfupdt = $time_formatter->format_datetime($time_dtf);
                            syslog(LOG_DEBUG, "%s: Gather config timestamps found run='%s'", $hostnameport, $cfupdt);
                        } elsif ( $stamp_type eq 'sav' ) {
                            $cfsavd = $time_formatter->format_datetime($time_dtf);
                            syslog(LOG_DEBUG, "%s: Gather config timestamps found saved='%s'", $hostnameport, $cfsavd);
                        }
                    }

                    # Spare some loop iterations.
                    if ( defined($cfupdt) && defined($cfsavd) ) {
                        last;
                    }
                }

                if ( defined($cfupdt) && defined($cfsavd) ) {
                    # Actually insert data.
                    $sth_update_dcapf_cfsavd_cfupdt->execute($cfsavd, $cfupdt, $hostnameport);
                    if ( defined($dbh->errstr) ) {
                        syslog(LOG_NOTICE, "%s: config timestamps: SQL execution error in: %s", $hostnameport, $dbh->errstr);
                    }
                } else {
                    syslog(LOG_NOTICE, "%s: config timestamps: could not extract both run and sav timestamp", $hostnameport);
                }
            } else {
                syslog(LOG_NOTICE, "%s: config timestamps: expect error %s encountered while trying 'show running-config', skipping",
                    $hostnameport, $err);
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
            @setnull_fields = ('asa_dm_ver', 'asa_fover', 'confreg', 'rld$reason', 'sysimg', 'uptime',
                'vtp_domain', 'vtp_mode', 'vtp_prune');
            foreach $setnull_field (@setnull_fields) {
                $dbh->do("UPDATE dcapf SET $setnull_field=NULL WHERE hostname='$hostnameport' AND $setnull_field IN ('', 'NULL')");
                if ( defined($dbh->errstr) ) {
                    syslog(LOG_NOTICE, "DB: SQL execution error for '%s' (text) in cleanup database: %s, skipping to next field",
                        $setnull_field, $dbh->errstr);
                }
            }

            # Numeric fields.
            @setnull_fields = ('uptime_min', 'vtp_vers');
            foreach $setnull_field (@setnull_fields) {
                $dbh->do("UPDATE dcapf SET $setnull_field=NULL WHERE hostname='$hostnameport' AND $setnull_field=-1");
                if ( defined($dbh->errstr) ) {
                    syslog(LOG_NOTICE, "DB: SQL execution error for '%s' (numeric) in cleanup database: %s, skipping to next field",
                        $setnull_field, $dbh->errstr);
                }
            }

            # Timestamp fields.
            @setnull_fields = ('cfsavd', 'cfupdt');
            foreach $setnull_field (@setnull_fields) {
                $dbh->do("UPDATE dcapf SET $setnull_field=NULL WHERE hostname='$hostnameport' AND \
                    $setnull_field='0001-01-01-00.00.00.000000'");
                if ( defined($dbh->errstr) ) {
                    syslog(LOG_NOTICE, "DB: SQL execution error for '%s' (stamp) in cleanup database: %s, skipping to next field",
                        $setnull_field, $dbh->errstr);
                }
            }
        }

        # One global commit per host: If we've come this far, things have worked out fine.
        syslog(LOG_DEBUG, "%s: DB: Committing all changes", $hostnameport);
        $dbh->do("commit");

    } else {
        syslog(LOG_WARNING, "%s: Host loop: could not obtain Expect-Handle, skipping host", $hostnameport);
    } # if Expect-Handle $cnh
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
                                syslog(LOG_NOTICE, "SCM: error %d while deleting orphaned '%s', skipping to next file",
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
            syslog(LOG_NOTICE, "SCM: error %d while committing, continuing anyway", $retval);
        }
    } else {
       if ((system( 'cd ' . $scmtmp . ' && git diff --quiet --cached --exit-code >/dev/null 2>&1') >> 8) == 1) {
            $retval = system( 'cd ' . $scmtmp . ' && git commit -q -m "Automatic Cisco-Config-Backup" >/dev/null 2>&1');
            $retval = ($retval >> 8);
            if ( $retval != 0 ) {
                syslog(LOG_NOTICE, "SCM: error %d while committing, continuing anyway", $retval);
            }
        } else {
            syslog(LOG_DEBUG, "SCM: No changes, nothing to commit");
        }
        syslog(LOG_DEBUG, "SCM: push changes");
        $retval = system( 'cd ' . $scmtmp . ' && git push -q >/dev/null 2>&1');
        $retval = ($retval >> 8);
        if ( $retval == 0 ) {
            syslog(LOG_DEBUG, "SCM: git push successful");
        } else {
            syslog(LOG_NOTICE, "SCM: error %d while pushing, continuing anyway", $retval);
        }
    }
}

# ------------------------------------------------------------------------------

# Delete orphaned entries from the database.
if ( $do_orphans == 1 ) {
    syslog(LOG_DEBUG, "DB: Delete orphaned entries");
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

# Uncommited changes after this point will be rolled back implicitly when closing the connection.

# Further cleanup is handled by the END block implicitly.
END {
    # $scmtmp housekeeping is done automatically through tempdir( CLEANUP => 1 );

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
    if ( $sth_update_dcapf_cfsavd_cfupdt ) {
        $sth_update_dcapf_cfsavd_cfupdt->finish;
    }
    if ( $sth_update_dcapf_cfsavd ) {
        $sth_update_dcapf_cfsavd->finish;
    }
    if ( $sth_update_dcapf_setasafailover ) {
        $sth_update_dcapf_setasafailover->finish;
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
    if ( $sth_select_count_hostname_scm ) {
        $sth_select_count_hostname_scm->finish;
    }
    if ( $dbh ) {
        $dbh->disconnect;
    }

    if (defined($cnh) ) {
        $cnh->send("exit\n");
        $cnh->soft_close();
    }

    closelog;
}

#--------------------------------------------------------------------------------------------------------------
# vim: tabstop=4 shiftwidth=4 autoindent colorcolumn=133 expandtab textwidth=132
# -EOF-
