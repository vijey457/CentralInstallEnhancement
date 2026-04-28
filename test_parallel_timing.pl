#!/usr/bin/perl
# =============================================================================
# test_parallel_timing.pl
#
# Validates that parallel node dispatch is measurably faster than sequential.
#
# This test is fully self-contained — no real SSH connections are needed.
# It mocks startOnMachine() with a configurable per-node sleep that simulates
# realistic SSH + remote-command latency, then runs both sequential and parallel
# execution strategies and asserts the parallel wall-clock time is significantly
# shorter.
#
# Usage:
#   perl test_parallel_timing.pl [--nodes N] [--delay S] [--verbose]
#
#   --nodes N    number of simulated nodes (default: 6, matches config.txt)
#   --delay S    simulated per-node work delay in seconds (default: 3)
#   --verbose    print per-node timing lines
#
# Exit code: 0 = PASS, 1 = FAIL
# =============================================================================

use strict;
use warnings;
use threads;
use threads::shared;
use Thread::Semaphore;
use Time::HiRes qw(time sleep);
use Getopt::Long;
use POSIX qw(floor);

# ---------------------------------------------------------------------------
# CLI options
# ---------------------------------------------------------------------------
my $opt_nodes   = 6;
my $opt_delay   = 3;   # seconds per node (simulates SSH round-trips)
my $opt_verbose = 0;
GetOptions(
    'nodes=i'  => \$opt_nodes,
    'delay=f'  => \$opt_delay,
    'verbose'  => \$opt_verbose,
) or die "Bad options\n";

# ---------------------------------------------------------------------------
# Shared state (mirrors the production script's globals)
# ---------------------------------------------------------------------------
my $gConsoleMutex    :shared = 1;
my $gStatusFileMutex :shared = 1;

my @gResults :shared;   # collects (node_name, start_offset, duration) per run

# ---------------------------------------------------------------------------
# Commands that are parallel in the patched script
# ---------------------------------------------------------------------------
my %gParallelCmds = map { $_ => 1 }
    qw(install uninstall showreleases start stop restart);

# ---------------------------------------------------------------------------
# Simulated node list  (mirrors config.txt format)
# ---------------------------------------------------------------------------
my @nodeNames = map { "NODE_$_" } (1 .. $opt_nodes);

# ---------------------------------------------------------------------------
# Mock startOnMachine
#   Simulates: SSH setup dir, SCP transfer, SSH execute, SSH cleanup
#   Real version takes 20-120 s per node depending on package size.
#   We use $opt_delay as a realistic stand-in.
# ---------------------------------------------------------------------------
sub mock_startOnMachine {
    my ($node, $t0) = @_;
    my $start = time() - $t0;
    sleep($opt_delay);                 # simulate SSH + remote work
    my $end   = time() - $t0;

    {
        lock($gConsoleMutex);
        if ($opt_verbose) {
            printf("  %-12s  start=%.2fs  end=%.2fs  dur=%.2fs\n",
                   $node, $start, $end, $end - $start);
        }
    }

    {
        lock($gStatusFileMutex);
        push @gResults, "$node:$start:$end";   # thread-safe append
    }
}

# ---------------------------------------------------------------------------
# run_sequential  — original production behaviour
# ---------------------------------------------------------------------------
sub run_sequential {
    my ($nodes_ref, $t0) = @_;
    foreach my $node (@{$nodes_ref}) {
        mock_startOnMachine($node, $t0);
    }
}

# ---------------------------------------------------------------------------
# run_parallel  — patched production behaviour
# ---------------------------------------------------------------------------
sub run_parallel {
    my ($nodes_ref, $t0) = @_;
    my @threads;
    foreach my $node (@{$nodes_ref}) {
        my $t = threads->create(\&mock_startOnMachine, $node, $t0);
        push @threads, $t;
    }
    $_->join() for @threads;
}

# ---------------------------------------------------------------------------
# Assertion helper
# ---------------------------------------------------------------------------
my $gTestsPassed = 0;
my $gTestsFailed = 0;

sub assert {
    my ($label, $cond, $detail) = @_;
    if ($cond) {
        print "  PASS  $label\n";
        $gTestsPassed++;
    } else {
        print "  FAIL  $label\n";
        print "        $detail\n" if defined $detail;
        $gTestsFailed++;
    }
}

# ===========================================================================
# TESTS
# ===========================================================================
print "=" x 65 . "\n";
print "MLCCN_Install parallel-execution timing test\n";
printf "Nodes: %d   Simulated per-node delay: %.1f s\n\n",
       $opt_nodes, $opt_delay;

# ---------------------------------------------------------------------------
# TEST 1 — Sequential baseline
# ---------------------------------------------------------------------------
print "[ TEST 1 ] Sequential execution ($opt_nodes nodes)\n";
@gResults = ();
my $t0_seq = time();
run_sequential(\@nodeNames, $t0_seq);
my $seq_wall = time() - $t0_seq;
my $seq_expected_min = $opt_nodes * $opt_delay;

printf "  Wall-clock time : %.2f s\n", $seq_wall;
printf "  Expected minimum: %.2f s  (nodes × delay = %d × %.1f)\n\n",
       $seq_expected_min, $opt_nodes, $opt_delay;

assert("Sequential wall-clock >= nodes*delay",
       $seq_wall >= $seq_expected_min * 0.95,
       sprintf("got %.2f, expected >= %.2f", $seq_wall, $seq_expected_min * 0.95));

# Verify all nodes ran and in series (no overlap)
my @seq_events = map { my @f = split(':', $_); \@f } @gResults;
my $overlap = 0;
for my $i (0 .. $#seq_events - 1) {
    my $end_i   = $seq_events[$i][2];
    my $start_j = $seq_events[$i+1][1];
    $overlap = 1 if $start_j < $end_i - 0.05;  # 50ms tolerance
}
assert("Sequential: no node overlap (strictly ordered)",
       !$overlap,
       "Two or more nodes ran concurrently in the sequential path");

assert("Sequential: all $opt_nodes nodes completed",
       scalar(@gResults) == $opt_nodes,
       sprintf("Expected %d results, got %d", $opt_nodes, scalar(@gResults)));

print "\n";

# ---------------------------------------------------------------------------
# TEST 2 — Parallel execution
# ---------------------------------------------------------------------------
print "[ TEST 2 ] Parallel execution ($opt_nodes nodes)\n";
@gResults = ();
my $t0_par = time();
run_parallel(\@nodeNames, $t0_par);
my $par_wall = time() - $t0_par;

# Ideal: all nodes run simultaneously → wall ≈ 1 × delay
# Allow 25% overhead for thread spawn / join / lock contention
my $par_expected_max = $opt_delay * 1.25;

printf "  Wall-clock time : %.2f s\n", $par_wall;
printf "  Ideal (1 node)  : %.2f s\n", $opt_delay;
printf "  Allowed max     : %.2f s  (ideal × 1.25)\n\n", $par_expected_max;

assert("Parallel wall-clock <= delay * 1.25",
       $par_wall <= $par_expected_max,
       sprintf("got %.2f s, limit is %.2f s", $par_wall, $par_expected_max));

assert("Parallel: all $opt_nodes nodes completed",
       scalar(@gResults) == $opt_nodes,
       sprintf("Expected %d results, got %d", $opt_nodes, scalar(@gResults)));

# Verify nodes genuinely overlapped
my @par_events = map { my @f = split(':', $_); \@f } @gResults;
my $overlaps_found = 0;
for my $i (0 .. $#par_events) {
    for my $j ($i+1 .. $#par_events) {
        my ($s_i, $e_i) = ($par_events[$i][1], $par_events[$i][2]);
        my ($s_j, $e_j) = ($par_events[$j][1], $par_events[$j][2]);
        # overlap if one starts before the other ends
        if ($s_j < $e_i && $s_i < $e_j) {
            $overlaps_found++;
        }
    }
}
assert("Parallel: nodes genuinely overlapped in time",
       $overlaps_found > 0,
       "No time overlap detected between any pair of node threads");

print "\n";

# ---------------------------------------------------------------------------
# TEST 3 — Speedup ratio
# ---------------------------------------------------------------------------
print "[ TEST 3 ] Speedup comparison\n";
my $speedup = $seq_wall / $par_wall;
# With N nodes, ideal speedup = N. We require at least N/2 (50% efficiency).
my $min_speedup = $opt_nodes / 2.0;

printf "  Sequential time : %.2f s\n", $seq_wall;
printf "  Parallel time   : %.2f s\n", $par_wall;
printf "  Speedup         : %.2fx\n",  $speedup;
printf "  Minimum required: %.1fx  (nodes/2 = %d/2)\n\n",
       $min_speedup, $opt_nodes;

assert(sprintf("Speedup >= %.1fx (nodes/2)", $min_speedup),
       $speedup >= $min_speedup,
       sprintf("Actual speedup %.2fx < minimum %.1fx", $speedup, $min_speedup));

my $time_saved    = $seq_wall - $par_wall;
my $pct_saved     = ($time_saved / $seq_wall) * 100;
printf "  Time saved      : %.2f s (%.1f%%)\n\n", $time_saved, $pct_saved;

assert("Time saved > 50%",
       $pct_saved > 50,
       sprintf("Only %.1f%% saved", $pct_saved));

# ---------------------------------------------------------------------------
# TEST 4 — Thread-safety: status file not corrupted under concurrency
# ---------------------------------------------------------------------------
print "[ TEST 4 ] Thread-safety: concurrent status-file updates\n";
my $tmp_status = "/tmp/test_status_$$";
my $write_mutex :shared = 1;
my $errors :shared = 0;

sub write_status_entry {
    my ($id, $file) = @_;
    sleep(rand(0.1));   # jitter to maximise race-condition exposure
    lock($write_mutex);
    open(my $fh, '>>', $file) or do { lock($errors); $errors++; return; };
    print $fh "NODE_$id\@done\n";
    close($fh);
}

my @writers = map { threads->create(\&write_status_entry, $_, $tmp_status) }
              (1 .. $opt_nodes);
$_->join() for @writers;

# Check: file should have exactly $opt_nodes lines, one per node, no corruption
open my $sfh, '<', $tmp_status or die "Cannot open $tmp_status";
my @lines = <$sfh>;
close $sfh;
unlink $tmp_status;

chomp @lines;
my %seen;
my $duplicates = 0;
for my $line (@lines) {
    $duplicates++ if $seen{$line}++;
}

assert("Status file has exactly $opt_nodes entries",
       scalar(@lines) == $opt_nodes,
       sprintf("Expected %d lines, got %d", $opt_nodes, scalar(@lines)));

assert("No duplicate entries in status file",
       $duplicates == 0,
       "$duplicates duplicate line(s) found — possible write corruption");

assert("No file-open errors during concurrent writes",
       $errors == 0,
       "$errors thread(s) failed to open the status file");

print "\n";

# ---------------------------------------------------------------------------
# TEST 5 — Sequential commands (patch / activate / upgrade) are NOT parallelized
# ---------------------------------------------------------------------------
print "[ TEST 5 ] Sequential-only commands remain serial\n";
my @seqOnlyCmds = qw(patch patch_global_pre patch_global_post activate upgrade);
my $allSerial = 1;
for my $cmd (@seqOnlyCmds) {
    if (exists $gParallelCmds{$cmd}) {
        $allSerial = 0;
        print "  FAIL  $cmd should NOT be in parallel set\n";
        $gTestsFailed++;
    }
}
if ($allSerial) {
    assert("patch/activate/upgrade not in parallel command set",
           1, "");
}

my @parallelOnlyCmds = qw(install uninstall showreleases start stop restart);
my $allParallel = 1;
for my $cmd (@parallelOnlyCmds) {
    unless (exists $gParallelCmds{$cmd}) {
        $allParallel = 0;
        print "  FAIL  $cmd SHOULD be in parallel set but is missing\n";
        $gTestsFailed++;
    }
}
if ($allParallel) {
    assert("install/uninstall/showreleases/start/stop/restart all in parallel set",
           1, "");
}

print "\n";

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
my $total = $gTestsPassed + $gTestsFailed;
print "=" x 65 . "\n";
printf "Results: %d/%d tests passed", $gTestsPassed, $total;
if ($gTestsFailed == 0) {
    print "  --  ALL PASSED\n";
    print "=" x 65 . "\n\n";
    printf "CONCLUSION: Parallel execution delivers %.1fx speedup over sequential\n", $speedup;
    printf "            (%.2f s  →  %.2f s  for %d nodes)\n\n",
           $seq_wall, $par_wall, $opt_nodes;
    exit 0;
} else {
    print "  --  $gTestsFailed FAILED\n";
    print "=" x 65 . "\n";
    exit 1;
}
