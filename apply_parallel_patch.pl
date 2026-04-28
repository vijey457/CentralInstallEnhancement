#!/usr/bin/perl
# =============================================================================
# apply_parallel_patch.pl
#
# Applies parallel-execution changes to MLCCN_Install_R12.4.1.26 and
# writes the result as MLCCN_Install_Vijey.pl.
#
# Usage:
#   perl apply_parallel_patch.pl MLCCN_Install_R12.4.1.26
#
# Output:
#   MLCCN_Install_Vijey.pl   (complete, ready-to-run patched script)
#   MLCCN_Install_R12.4.1.26.orig  (untouched backup of the original)
#
# What this patch does (5 surgical changes):
#   1. Replaces the deprecated Thread module with threads + Thread::Semaphore
#   2. Declares $gStatusFileMutex, $gConsoleMutex, %gParallelCmds globals
#   3. Wraps updateStatusFile() with $gStatusFileMutex  (prevents race on
#      .status_<cmd> read-modify-write from concurrent threads)
#   4. Wraps logToFile() console print with $gConsoleMutex  (prevents
#      interleaved output from parallel node threads)
#   5. Replaces the sequential foreach in handleRemoteOp() with a
#      thread-per-node fan-out + join for the listed commands
#
# Commands that run in PARALLEL across nodes:
#   install  uninstall  showreleases  start  stop  restart
#
# Commands that remain SEQUENTIAL (by design):
#   patch  patch_global_pre  patch_global_post  activate  upgrade
#   (patch has ordered global-pre/per-node/global-post fence points;
#    activate and upgrade are interactive one-at-a-time operations)
# =============================================================================

use strict;
use warnings;
use File::Copy;

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
sub slurp {
    my $f = shift;
    open my $fh, '<', $f or die "Cannot read '$f': $!\n";
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub spew {
    my ($f, $c) = @_;
    open my $fh, '>', $f or die "Cannot write '$f': $!\n";
    print $fh $c;
    close $fh;
}

sub apply {
    my ($src_ref, $label, $from, $to) = @_;
    if ($$src_ref =~ /\Q$from\E/) {
        $$src_ref =~ s/\Q$from\E/$to/;
        print "  [OK]   $label\n";
        return 1;
    } else {
        warn "  [WARN] $label\n";
        warn "         Pattern not found — already patched or version mismatch.\n";
        return 0;
    }
}

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------
my $infile  = $ARGV[0] or die "Usage: $0 <MLCCN_Install_script>\n";
die "File not found: $infile\n" unless -f $infile;

my $outfile = 'MLCCN_Install_Vijey.pl';
my $backup  = "$infile.orig";

unless (-f $backup) {
    copy($infile, $backup) or die "Cannot create backup '$backup': $!\n";
    print "Backup  : $backup\n";
} else {
    print "Backup  : $backup (already exists — skipped)\n";
}

my $src = slurp($infile);
my $applied = 0;

print "\nApplying parallel-execution patches to produce $outfile ...\n\n";

# ---------------------------------------------------------------------------
# PATCH 1 — Replace deprecated Thread module
# ---------------------------------------------------------------------------
$applied += apply(\$src,
    'PATCH 1 — replace Thread with threads + Thread::Semaphore',

    "use Thread;\nno warnings 'threads';",

    "use threads;\n"
  . "use threads::shared;\n"
  . "use Thread::Semaphore;\n"
  . "no warnings 'threads';"
);

# ---------------------------------------------------------------------------
# PATCH 2 — Insert shared mutexes and %gParallelCmds after $gPeerSockFd
# ---------------------------------------------------------------------------
$applied += apply(\$src,
    'PATCH 2 — add $gStatusFileMutex, $gConsoleMutex, %gParallelCmds',

    "my \$gCentralizedOp = false;\n"
  . "my \$gPeerSockFd;",

    "my \$gCentralizedOp = false;\n"
  . "my \$gPeerSockFd;\n\n"
  . "# -----------------------------------------------------------------------\n"
  . "# Thread-safety primitives (parallel node dispatch)\n"
  . "# \$gStatusFileMutex : serialises read-modify-write of .status_<cmd> files\n"
  . "#                      so concurrent threads don't corrupt progress state.\n"
  . "# \$gConsoleMutex    : serialises STDOUT so per-node log lines don't\n"
  . "#                      interleave across threads.\n"
  . "# -----------------------------------------------------------------------\n"
  . "my \$gStatusFileMutex :shared = 1;\n"
  . "my \$gConsoleMutex    :shared = 1;\n\n"
  . "# Commands dispatched in parallel to all nodes in the config file.\n"
  . "# patch* / activate / upgrade are intentionally kept sequential:\n"
  . "#   patch  - has ordered global-pre / per-node / global-post phases.\n"
  . "#   activate / upgrade - interactive; one answer applies to every node.\n"
  . "my \%gParallelCmds = map { \$_ => 1 }\n"
  . "    qw(install uninstall showreleases start stop restart);"
);

# ---------------------------------------------------------------------------
# PATCH 3 — Protect logToFile console print with $gConsoleMutex
# ---------------------------------------------------------------------------
$applied += apply(\$src,
    'PATCH 3 — serialize logToFile console output with $gConsoleMutex',

    "\tif(\$printOnScreen || (defined \$logEnabled && \$logEnabled eq \"true\")) {\n"
  . "\t\tif(\$gCentralizedOp == true) {\n"
  . "\t\t\tprint \"\$log\\n\";\n"
  . "\t\t} else {\n"
  . "\t\t\t#print color(\$colour), ON_BLACK \"\$log\\n\";\n"
  . "\t\t\tprint \"\$log\\n\";\n"
  . "\t\t}\n"
  . "\t}",

    "\tif(\$printOnScreen || (defined \$logEnabled && \$logEnabled eq \"true\")) {\n"
  . "\t\tlock(\$gConsoleMutex);   # prevent interleaved output from parallel threads\n"
  . "\t\tif(\$gCentralizedOp == true) {\n"
  . "\t\t\tprint \"\$log\\n\";\n"
  . "\t\t} else {\n"
  . "\t\t\t#print color(\$colour), ON_BLACK \"\$log\\n\";\n"
  . "\t\t\tprint \"\$log\\n\";\n"
  . "\t\t}\n"
  . "\t}"
);

# ---------------------------------------------------------------------------
# PATCH 4 — Protect updateStatusFile with $gStatusFileMutex
# ---------------------------------------------------------------------------
$applied += apply(\$src,
    'PATCH 4 — acquire $gStatusFileMutex at start of updateStatusFile',

    "sub updateStatusFile (\$\$\$)\n"
  . "{\n"
  . "\tmy \$ipaddr = shift;\n"
  . "\tmy \$entry = shift;\n"
  . "\tmy \$statusFile = shift;\n\n"
  . "\tmy \@entries = ();\n"
  . "\tif (open(CONF, \"<\",\$statusFile)) {",

    "sub updateStatusFile (\$\$\$)\n"
  . "{\n"
  . "\tmy \$ipaddr = shift;\n"
  . "\tmy \$entry = shift;\n"
  . "\tmy \$statusFile = shift;\n\n"
  . "\t# Serialise concurrent status-file updates from parallel threads.\n"
  . "\t# lock() releases automatically when the sub returns (scope-based).\n"
  . "\tlock(\$gStatusFileMutex);\n\n"
  . "\tmy \@entries = ();\n"
  . "\tif (open(CONF, \"<\",\$statusFile)) {"
);

# ---------------------------------------------------------------------------
# PATCH 5 — Replace sequential foreach in handleRemoteOp with parallel dispatch
# ---------------------------------------------------------------------------
$applied += apply(\$src,
    'PATCH 5 — parallel thread-per-node dispatch in handleRemoteOp',

    "\tforeach my \$param (\@{\$remoteMCs}) {\n"
  . "\t\tstartOnMachine(\$prompts, \$param, \$files, \$selfIp);\n"
  . "\t}\n\n"
  . "\tunlink(\$gPromptsFile);",

    "\t# ---------------------------------------------------------------\n"
  . "\t# Dispatch: parallel for listed commands, sequential for the rest.\n"
  . "\t# ---------------------------------------------------------------\n"
  . "\tif (exists \$gParallelCmds{\$command}) {\n"
  . "\t\tmy \$nodeCount = scalar(\@{\$remoteMCs});\n"
  . "\t\tlogToFile(\n"
  . "\t\t\t\"PARALLEL: dispatching \$command to \$nodeCount node(s) concurrently\",\n"
  . "\t\t\tLOGINFO | LOGCONS);\n\n"
  . "\t\tmy \@workerThreads;\n"
  . "\t\tforeach my \$param (\@{\$remoteMCs}) {\n"
  . "\t\t\tmy \$t = threads->create(\n"
  . "\t\t\t\t\\&startOnMachine,\n"
  . "\t\t\t\t\$prompts, \$param, \$files, \$selfIp\n"
  . "\t\t\t);\n"
  . "\t\t\tpush \@workerThreads, \$t;\n"
  . "\t\t}\n\n"
  . "\t\t# Block until every node thread has finished.\n"
  . "\t\tforeach my \$t (\@workerThreads) {\n"
  . "\t\t\t\$t->join();\n"
  . "\t\t}\n\n"
  . "\t\tlogToFile(\n"
  . "\t\t\t\"PARALLEL: all \$nodeCount node(s) completed \$command\",\n"
  . "\t\t\tLOGINFO | LOGCONS);\n\n"
  . "\t} else {\n"
  . "\t\t# Sequential path — preserved for patch / activate / upgrade.\n"
  . "\t\tforeach my \$param (\@{\$remoteMCs}) {\n"
  . "\t\t\tstartOnMachine(\$prompts, \$param, \$files, \$selfIp);\n"
  . "\t\t}\n"
  . "\t}\n\n"
  . "\tunlink(\$gPromptsFile);"
);

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------
print "\n";
if ($applied == 5) {
    spew($outfile, $src);
    print "All 5 patches applied successfully.\n";
    print "Output  : $outfile\n\n";

    # Syntax check
    my $check = `perl -c "$outfile" 2>&1`;
    chomp $check;
    if ($check =~ /syntax OK/) {
        print "Syntax  : $outfile syntax OK\n";
    } else {
        warn "Syntax  : WARNING — perl -c reported:\n$check\n";
    }
} else {
    my $missed = 5 - $applied;
    warn "$missed patch(es) were not applied (see WARN lines above).\n";
    warn "The output file has NOT been written to avoid producing a broken script.\n";
    warn "Check that the input file is the original MLCCN_Install_R12.4.1.26.\n";
    exit 1;
}

print "\nUsage after patching:\n";
print "  ./$outfile -c=config.txt install\n";
print "  ./$outfile -c=config.txt start\n";
print "  ./$outfile -c=config.txt stop\n";
print "  ./$outfile -c=config.txt restart\n";
print "  ./$outfile -c=config.txt uninstall\n";
print "  ./$outfile -c=config.txt showreleases\n\n";
