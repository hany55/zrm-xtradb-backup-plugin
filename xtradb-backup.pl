#!/usr/bin/perl
#
# Copyright (c) 2011 VM Farms.  All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License version 2 as published
# by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 59 Temple Place, Suite 330, Boston, MA  02111-1307 USA
#

use strict;
use Getopt::Long;
use File::Spec::Functions;
use File::Glob ':globally';
use File::Copy;
use POSIX ":sys_wait_h";

$ENV{"PATH"} = "/usr/local/bin:/opt/csw/bin:/usr/bin:/bin:/sbin:/usr/sbin";

my $XB_BINPATH = "/usr/bin";
my $XTRABACKUP = "xtrabackup";

my $VERSION = "0.1";
my $logFile = "/var/log/mysql-zrm/xtra-backup.log";
my $destDir;
my $srcDir;
my @params;
my $copyFrm       = 1;
my $doublePrepare = 0;
my $saveMyCnf     = 1;
my $ihbDataDir;
my $ihbDatabases;
my $ihbTables;
my $suspendFile;

my %config;

open LOG, ">$logFile" or die "Unable to create log file";

sub printLog() {
    print LOG $_[0];
}

sub printAndDie() {
    &printLog("ERROR: $_[0]");
    &my_exit(1);
}

sub parseConfFile() {
    my $fileName = $ENV{'ZRM_CONF'};
    unless ( open( FH, "$fileName" ) ) {
        die "Unable to open config file $fileName\n";
    }
    my @tmparr = <FH>;
    close(FH);
    chomp(@tmparr);
    foreach (@tmparr) {
        my @v  = split( /=/, $_ );
        my $v1 = shift @v;
        my $v2 = join( "=", @v );
        $config{$v1} = $v2;
    }
}

# Parses the command line for all of the copy parameters
sub getXBParameters() {
    my %opt;
    my $ret = GetOptions( \%opt, "destination-directory=s" );

    unless ($ret) {
        die("Invalid parameters");
    }

    if ( !$opt{"destination-directory"} ) {
        die("No destination file defined");
    }
    else {
        $destDir = $opt{"destination-directory"};
    }
}

# Make sure we have all the required options
sub checkForRequiredParams () {
    if (!$ihbDataDir) {
        &printLog("MYSQL data directory not defined in my.cnf, mysql-zrm.conf or command line: |$ihbDataDir|\n");
        die("MYSQL data directory not defined in my.cnf, mysql-zrm.conf or command line.");
    }
}

# Setup the parameters that are relevant from the conf
# These will all be read in from the my.cnf file
sub setUpConfParams() {
    if ( defined($config{"xdb-save-mycnf"}) ) {
        $saveMyCnf = $config{"xdb-save-mycnf"};
    }
    if ( defined($config{"xdb-double-prepare"}) ) {
        $doublePrepare = $config{"xdb-double-prepare"};
    }
    if ( defined($config{"xdb-copy-frm"}) ) {
        $copyFrm = $config{"xdb-copy-frm"};
    }
    if ( $config{"xdb-throttle"} ) {
        push( @params, "--throttle=" . $config{"xdb-throttle"} );
    }
    if ( $config{"xdb-use-memory"} ) {
        push( @params, "--use-memory=" . $config{"xdb-use-memory"} );
    }
    if ( $config{"xdb-parallel"} ) {
        push( @params, "--parallel=" . $config{"xdb-parallel"} );
    }

    if ( $config{"ihb-datadir"} ) {
        $ihbDataDir = $config{"ihb-datadir"};
    }
    if ( $config{"ihb-databases"} ) {
        $ihbDatabases = $config{"ihb-databases"};
    }
    if ( $config{"ihb-tables"} ) {
        $ihbTables = $config{"ihb-tables"};
    }
}

# Fire up xtrabackup as a background process with --suspend-at-end, 
# so we can copy *.frm and *.opt files.
sub startXtrabackup() {
    &printLog("cmd:@_\n");
    if ( defined( my $pid = fork ) ) {
        if ($pid) {
            # parent process
            return ($pid);
        }
        else {
            # child process
            my $r = exec(@_);
        }
    }
}

# Wait for backup process to finish
sub waitForSuspend() {
    while ( !-e $suspendFile ) {
        if ( $_[0] == waitpid( $_[0], &WNOHANG ) ) {
            die "xtrabackup child process exited with ".($?/256);
        }
        sleep 1;
    }
}

sub copySupport() {
    &printLog("Datadir: $ihbDataDir\n");
    &printLog("Databases: $ihbDatabases\n");
    &printLog("Tables: $ihbTables\n");

    # Copy innodb support files for consistent backups
    for my $innoDb ( split( / /, $ihbDatabases ) ) {
        my $innoDbDir = catfile( $ihbDataDir, $innoDb );
        &printLog("Path: $innoDbDir\n");
        my $dbBackupDir = catfile( $destDir, $innoDb );
        unless(-d $dbBackupDir) { mkdir($dbBackupDir) || die ("could not create backup dir $dbBackupDir\n"); }
        my @frmFiles = glob( $innoDbDir . "/*.{frm,opt}" );
        for my $frmFile (@frmFiles) {
            &printLog("Backing-up file: $frmFile to $dbBackupDir\n");
            copy( $frmFile, $dbBackupDir )
              or die(
"xtrabackup plugin could not copy $frmFile to backup directory\n"
              );
        }
    }
}

sub doXBBackup() {
    my @cmd;
    my $xtrabackup = catfile( $XB_BINPATH, $XTRABACKUP );
    my $target = "--target-dir=" . $destDir;

    $suspendFile = catfile( $destDir, "xtrabackup_suspended" );

    push( @cmd, $xtrabackup );
    push( @cmd, "--backup" );
    push( @cmd, @params );
    push( @cmd, $target );
    if ( $copyFrm == 1 ) {
        push ( @cmd, "--suspend-at-end" );
    }

    # Execute the backup script with suspend so we can grab the .frm files
    &printLog("Fork and executing command: @cmd\n");
    my $childPid = &startXtrabackup(@cmd);

    if ( $saveMyCnf == 1 ) {
        my $output = `$xtrabackup --print-param`;
        my $myCnf = catfile($destDir, "my.cnf");

        open MYCNF, ">$myCnf" or die "Unable to create my.cnf file";
	print MYCNF "$output";
        close(MYCNF);
    }

    &waitForSuspend($childPid);

    &printLog("Backing up .frm and .opt files.\n");
    if ( $copyFrm == 1 ) {
        &copySupport();
        &printLog(
            "Finished backing up .frm and .opt files, unlinking suspend-at-end.\n");
        unlink($suspendFile);
    }

    &printLog("Completed hot backup of innodb databases.\n");
}

sub prepareBackup() {
    my $xtrabackup = catfile( $XB_BINPATH, $XTRABACKUP );
    my $target     = "--target-dir=" . $destDir;
    my @prepCmd    = ( $xtrabackup, $target );

    push( @prepCmd, "--prepare" );
    &printLog("Preparing the database with cmd: @prepCmd\n");
    &startXtrabackup(@prepCmd);
}

# Main
&parseConfFile();
&setUpConfParams();
&getXBParameters();
&checkForRequiredParams();

&doXBBackup();

waitpid( &prepareBackup(), 0 );
if ( $doublePrepare == 1 ) {
    waitpid( &prepareBackup(), 0 );
}

exit(0);
