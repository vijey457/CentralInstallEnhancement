#!/usr/bin/perl
# =============================================================================
# Vijay_Patch.pl
#
# PURPOSE
#   Reads the original MLCCN_Install_R12.4.1.26 (or any release), applies
#   exactly SIX surgical changes to convert the centralized-install loop from
#   sequential to parallel, and writes the result as Vijay_Install.pl.
#
#   Every line of the original that is NOT one of the six target patterns
#   is written to the output file UNCHANGED.
#
# USAGE
#   perl Vijay_Patch.pl MLCCN_Install_R12.4.1.26
#
# OUTPUT
#   Vijay_Install.pl   — parallel-enabled script, ready to run
#
# THE SIX CHANGES (all other lines are byte-for-byte identical to the original)
# ---------------------------------------------------------------------------
# C1  use Thread;
#       → use threads; use threads::shared; use Thread::Semaphore;
#
# C2  my $gPeerSockFd;          (first occurrence)
#       → same line, then INSERT shared-mutex + %gParallelCmds block
#
# C3  Inside logToFile() — the "if($printOnScreen …)" console-print block
#       → INSERT lock($gConsoleMutex) before the print
#
# C4  Inside updateStatusFile() — first line after the three "shift" lines
#       → INSERT lock($gStatusFileMutex)
#
# C5  Inside handleRemoteOp() — the sequential "foreach my $param (@{$remoteMCs})"
#       → REPLACE with thread-per-node fan-out + join
#
# C6  Inside setUpServer() — "new Thread \&acceptAndRecv, $sockFd"
#       → threads->create(\&acceptAndRecv, $sockFd)->detach()
# =============================================================================

use strict;
use warnings;
use File::Copy;

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------
my $infile  = $ARGV[0] or die "Usage: $0 <MLCCN_Install_script>\n";
die "File not found or empty: $infile\n" unless -f $infile && -s $infile;

my $outfile = 'Vijay_Install.pl';
my $backup  = "$infile.orig";

unless (-f $backup) {
    copy($infile, $backup) or die "Cannot create backup '$backup': $!\n";
    print "Backup  : $backup\n";
} else {
    print "Backup  : $backup (already exists — skipped)\n";
}

open my $in,  '<', $infile  or die "Cannot read '$infile': $!\n";
open my $out, '>', $outfile or die "Cannot write '$outfile': $!\n";

# ---------------------------------------------------------------------------
# State tracking
# ---------------------------------------------------------------------------
my %applied = map { $_ => 0 } qw(C1 C2 C3 C4 C5 C6);

# Sub-state for multi-line replacements
my $in_logToFile        = 0;   # inside logToFile sub body
my $in_updateStatus     = 0;   # inside updateStatusFile sub body
my $in_handleRemote     = 0;   # inside handleRemoteOp sub body
my $in_setUpServer      = 0;   # inside setUpServer sub body
my $shift_count         = 0;   # counts "shift" lines at top of updateStatusFile
my $c3_done_this_sub    = 0;   # C3 applied once per logToFile
my $c4_done_this_sub    = 0;   # C4 applied once per updateStatusFile
my $c5_done             = 0;   # C5 one-shot
my $skip_old_foreach    = 0;   # swallowing the old sequential foreach block
my $brace_depth         = 0;   # brace depth inside handleRemoteOp (for C5 scope)

# ---------------------------------------------------------------------------
# Inserted text blocks
# ---------------------------------------------------------------------------

my $C2_INSERT = <<'C2END';

# -----------------------------------------------------------------------
# Thread-safety primitives (parallel node dispatch)
# $gStatusFileMutex : serialises read-modify-write of .status_<cmd> files
#                      so concurrent threads don't corrupt progress state.
# $gConsoleMutex    : serialises STDOUT so per-node log lines don't
#                      interleave across threads.
# -----------------------------------------------------------------------
my $gStatusFileMutex :shared = 1;
my $gConsoleMutex    :shared = 1;

# Commands dispatched in parallel to all nodes in the config file.
# patch* / activate / upgrade are intentionally kept sequential:
#   patch  - has ordered global-pre / per-node / global-post phases.
#   activate / upgrade - interactive; one answer applies to every node.
my %gParallelCmds = map { $_ => 1 }
    qw(install uninstall showreleases start stop restart);
C2END

# C5: replacement for the sequential foreach block in handleRemoteOp
# The original block we replace is:
#   foreach my $param (@{$remoteMCs}) {
#       startOnMachine($prompts, $param, $files, $selfIp);
#   }
#
#   unlink($gPromptsFile);
#
# We write the parallel dispatch instead:
my $C5_REPLACE = <<'C5END';
	# ---------------------------------------------------------------
	# Dispatch: parallel for listed commands, sequential for the rest.
	# ---------------------------------------------------------------
	if (exists $gParallelCmds{$command}) {
		my $nodeCount = scalar(@{$remoteMCs});
		logToFile(
			"PARALLEL: dispatching $command to $nodeCount node(s) concurrently",
			LOGINFO | LOGCONS);

		my @workerThreads;
		foreach my $param (@{$remoteMCs}) {
			my $t = threads->create(
				\&startOnMachine,
				$prompts, $param, $files, $selfIp
			);
			push @workerThreads, $t;
		}

		# Block until every node thread has finished.
		foreach my $t (@workerThreads) {
			$t->join();
		}

		logToFile(
			"PARALLEL: all $nodeCount node(s) completed $command",
			LOGINFO | LOGCONS);

	} else {
		# Sequential path — preserved for patch / activate / upgrade.
		foreach my $param (@{$remoteMCs}) {
			startOnMachine($prompts, $param, $files, $selfIp);
		}
	}

	unlink($gPromptsFile);
C5END

# ---------------------------------------------------------------------------
# Line-by-line processing
# ---------------------------------------------------------------------------
while (my $line = <$in>) {

    # ====================================================================
    # C1 — replace "use Thread;" with the three modern-thread use lines
    # ====================================================================
    if (!$applied{C1} && $line =~ /^\s*use\s+Thread\s*;\s*$/) {
        print $out "use threads;\n";
        print $out "use threads::shared;\n";
        print $out "use Thread::Semaphore;\n";
        $applied{C1} = 1;
        print "  [C1 OK] use Thread -> use threads + shared + Semaphore\n";
        next;
    }

    # ====================================================================
    # C2 — insert shared globals after first "my $gPeerSockFd" declaration
    # ====================================================================
    if (!$applied{C2} && $line =~ /^\s*my\s+\$gPeerSockFd\s*;/) {
        print $out $line;          # write the original line first
        print $out $C2_INSERT;
        $applied{C2} = 1;
        print "  [C2 OK] Inserted \$gStatusFileMutex, \$gConsoleMutex, %gParallelCmds\n";
        next;
    }

    # ====================================================================
    # Track sub boundaries for C3 / C4 / C5 / C6
    # ====================================================================
    if ($line =~ /^sub\s+logToFile\b/)        { $in_logToFile    = 1; $c3_done_this_sub = 0; }
    if ($line =~ /^sub\s+updateStatusFile\b/) { $in_updateStatus = 1; $c4_done_this_sub = 0; $shift_count = 0; }
    if ($line =~ /^sub\s+handleRemoteOp\b/)   { $in_handleRemote = 1; $brace_depth = 0; }
    if ($line =~ /^sub\s+setUpServer\b/)      { $in_setUpServer  = 1; }

    # Close sub tracking when we hit the next top-level sub
    if ($line =~ /^sub\s+\w+/ ) {
        unless ($line =~ /^sub\s+logToFile\b/)        { $in_logToFile    = 0; }
        unless ($line =~ /^sub\s+updateStatusFile\b/) { $in_updateStatus = 0; }
        unless ($line =~ /^sub\s+handleRemoteOp\b/)   { $in_handleRemote = 0; }
        unless ($line =~ /^sub\s+setUpServer\b/)       { $in_setUpServer  = 0; }
    }

    # ====================================================================
    # C3 — add lock($gConsoleMutex) inside logToFile before console print
    # Targets the line:  if($printOnScreen || ...
    # ====================================================================
    if ($in_logToFile && !$applied{C3} && !$c3_done_this_sub
        && $line =~ /if\s*\(\s*\$printOnScreen\s*\|\|/) {
        print $out $line;
        print $out "\t\tlock(\$gConsoleMutex);   # prevent interleaved output from parallel threads\n";
        $applied{C3}      = 1;
        $c3_done_this_sub = 1;
        print "  [C3 OK] lock(\$gConsoleMutex) inserted in logToFile\n";
        next;
    }

    # ====================================================================
    # C4 — add lock($gStatusFileMutex) at top of updateStatusFile body.
    # Inserts after the third "shift" line (all three args have been read).
    # ====================================================================
    if ($in_updateStatus && !$applied{C4} && !$c4_done_this_sub) {
        if ($line =~ /\bshift\b/) {
            $shift_count++;
            print $out $line;
            if ($shift_count == 3) {
                print $out "\n";
                print $out "\t# Serialise concurrent status-file updates from parallel threads.\n";
                print $out "\t# lock() releases automatically when the sub returns (scope-based).\n";
                print $out "\tlock(\$gStatusFileMutex);\n";
                $applied{C4}      = 1;
                $c4_done_this_sub = 1;
                print "  [C4 OK] lock(\$gStatusFileMutex) inserted in updateStatusFile\n";
            }
            next;
        }
    }

    # ====================================================================
    # C5 — replace sequential foreach in handleRemoteOp with parallel
    # dispatch.  We detect:
    #   foreach my $param (@{$remoteMCs}) {
    #       startOnMachine(
    # and swallow lines until (and including) the matching closing brace,
    # then also swallow the blank line + "unlink($gPromptsFile);" line,
    # then emit our replacement block.
    # ====================================================================
    if ($in_handleRemote && !$applied{C5}) {

        # Detect start of the old sequential foreach
        if (!$skip_old_foreach
            && $line =~ /foreach\s+my\s+\$param\s*\(\@\{\s*\$remoteMCs\s*\}\)/) {
            $skip_old_foreach = 1;
            $brace_depth      = 0;
        }

        if ($skip_old_foreach) {
            # Count braces to find end of the foreach block
            my $opens  = () = $line =~ /\{/g;
            my $closes = () = $line =~ /\}/g;
            $brace_depth += $opens - $closes;

            if ($brace_depth <= 0 && $line =~ /\}/) {
                # We've closed the foreach block — now look for unlink line
                $skip_old_foreach = 2;   # state: swallowing trailing lines
            }
            next;   # swallow this line
        }

        if ($skip_old_foreach == 2) {
            # Swallow blank lines and the unlink($gPromptsFile) line
            if ($line =~ /^\s*$/ || $line =~ /unlink\s*\(\s*\$gPromptsFile\s*\)/) {
                if ($line =~ /unlink\s*\(\s*\$gPromptsFile\s*\)/) {
                    # Emit the full parallel replacement (includes unlink)
                    print $out $C5_REPLACE;
                    $applied{C5}      = 1;
                    $skip_old_foreach = 0;
                    print "  [C5 OK] Parallel thread dispatch inserted in handleRemoteOp\n";
                }
                next;
            }
            # Something unexpected — stop swallowing
            $skip_old_foreach = 0;
        }
    }

    # ====================================================================
    # C6 — replace "new Thread \&acceptAndRecv, $sockFd" in setUpServer
    # ====================================================================
    if ($in_setUpServer && !$applied{C6}
        && $line =~ /new\s+Thread\s+\\&acceptAndRecv/) {
        # Preserve leading whitespace
        my ($indent) = $line =~ /^(\s*)/;
        print $out "${indent}my \$thread = threads->create(\\&acceptAndRecv, \$sockFd);\n";
        print $out "${indent}\$thread->detach();   # runs independently; controller never joins it\n";
        $applied{C6} = 1;
        print "  [C6 OK] new Thread -> threads->create()->detach() in setUpServer\n";
        next;
    }

    # ====================================================================
    # Default — write line unchanged
    # ====================================================================
    print $out $line;
}

close $in;
close $out;

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
print "\n";
my $ok    = grep { $applied{$_} } keys %applied;
my $total = scalar keys %applied;

if ($ok == $total) {
    print "All $total changes applied successfully.\n";
    print "Output  : $outfile\n\n";

    my $check = `perl -c "$outfile" 2>&1`;
    chomp $check;
    if ($check =~ /syntax OK/) {
        print "Syntax  : $outfile syntax OK\n";
    } else {
        warn "Syntax  : WARNING — perl -c reported:\n$check\n";
    }
} else {
    warn "${\($total - $ok)} change(s) were NOT applied:\n";
    for my $c (sort keys %applied) {
        warn "  $c — MISSING\n" unless $applied{$c};
    }
    warn "\nCheck that the input file is the correct MLCCN_Install_R12.4.1.26.\n";
    warn "The output file '$outfile' has been written but may be incomplete.\n";
    exit 1;
}

print "\nUsage after patching:\n";
print "  chmod +x $outfile\n";
print "  ./$outfile -c=config.txt install      # parallel across all nodes\n";
print "  ./$outfile -c=config.txt start\n";
print "  ./$outfile -c=config.txt stop\n";
print "  ./$outfile -c=config.txt restart\n";
print "  ./$outfile -c=config.txt showreleases\n";
print "  ./$outfile -c=config.txt upgrade      # still sequential (interactive)\n";
print "  ./$outfile -o=abort install           # abort an in-progress operation\n\n";
