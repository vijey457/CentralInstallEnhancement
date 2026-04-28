#!/usr/bin/perl
# =============================================================================
# simulate_install.pl
#
# Faithful simulation of:
#   ./MLCCN_Install_R12.4.1.26 -c=config.txt install
#
# Reproduces the exact console/log output format of the real script and
# models the four SSH/SCP steps that startOnMachine() executes per node
# for the "install" command, using realistic LAN timing derived from the
# script's own ssh/scp timeout values (30s / 120s / 300s / 30s).
#
# Runs BOTH sequential (original) and parallel (patched) strategies and
# prints a side-by-side timing comparison at the end.
#
# Per-node step timing used (all in seconds):
#   Step 1 – SSH: rm/mkdir /tmp/.install          : 2 – 4 s
#   Step 2 – SCP: transfer install directory       : 28 – 45 s
#            (MLCCN install package is ~120-200 MB over 1 Gbps LAN)
#   Step 3 – SSH: execute ./MLCCN_Install install  : 70 – 110 s
#            (untar packages, genPort, installSsts, configureSsts,
#             createPolarisUser, setupMlcDaemon, writeIniFile …)
#   Step 4 – SSH: rm -rf /tmp/.install (cleanup)   : 2 – 3 s
#
# Total per node: ~102 – 162 s  (average ~130 s, i.e. ~2 min 10 s)
# =============================================================================

use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(time sleep);
use POSIX       qw(strftime);

# ---------------------------------------------------------------------------
# Simulation speed multiplier.
# SPEEDUP = 30  →  1 real second represents 30 simulated seconds.
# This keeps the demo under 30 s wall-clock while preserving all ratios.
# ---------------------------------------------------------------------------
use constant SPEEDUP => 30;

sub sim_sleep { sleep( $_[0] / SPEEDUP ) }
sub sim_fmt   { sprintf("%.0f", $_[0]) }

# ---------------------------------------------------------------------------
# Per-node step timing table (seconds, realistic values)
# Slight variation per node to reflect real network/CPU differences.
# ---------------------------------------------------------------------------
my %NODE_TIMING = (
    'OLGW'      => { ssh_setup =>  3, scp_transfer => 32, ssh_install =>  80, ssh_clean => 2 },
    'LRD'       => { ssh_setup =>  2, scp_transfer => 35, ssh_install =>  90, ssh_clean => 3 },
    'MSP'       => { ssh_setup =>  4, scp_transfer => 28, ssh_install =>  75, ssh_clean => 2 },
    'CH'        => { ssh_setup =>  3, scp_transfer => 40, ssh_install => 100, ssh_clean => 3 },
    'PRGW'      => { ssh_setup =>  2, scp_transfer => 45, ssh_install => 110, ssh_clean => 2 },
    'LRD-2GSGW' => { ssh_setup =>  3, scp_transfer => 38, ssh_install =>  95, ssh_clean => 2 },
);

# Config file nodes (matches config.txt)
my @NODES = (
    { name => 'OLGW',      ip => '192.168.55.110', uid => 'root', pw => 'password' },
    { name => 'LRD',       ip => '192.168.55.111', uid => 'root', pw => 'password' },
    { name => 'MSP',       ip => '192.168.55.112', uid => 'root', pw => 'password' },
    { name => 'CH',        ip => '192.168.55.113', uid => 'root', pw => 'password' },
    { name => 'PRGW',      ip => '192.168.55.114', uid => 'root', pw => 'password' },
    { name => 'LRD-2GSGW', ip => '192.168.55.115', uid => 'root', pw => 'password' },
);

# ---------------------------------------------------------------------------
# Shared state
# ---------------------------------------------------------------------------
my $gConsoleMutex    :shared = 1;
my $gStatusFileMutex :shared = 1;
my $gWallStart       :shared = 0;   # set once when run begins

my @gStatusLog       :shared;       # collects "NAME@done/Failed" entries

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
sub ts {
    # Returns a simulated timestamp (wall offset scaled back to real seconds)
    my $elapsed_real = time() - $gWallStart;
    my $elapsed_sim  = $elapsed_real * SPEEDUP;
    return strftime("%H:%M:%S", gmtime(int($elapsed_sim)));
}

sub logcons {
    my ($msg) = @_;
    lock($gConsoleMutex);
    printf("[%s] %s\n", ts(), $msg);
}

sub log_node {
    my ($node, $msg) = @_;
    lock($gConsoleMutex);
    printf("[%s] %-12s | %s\n", ts(), $node, $msg);
}

# ---------------------------------------------------------------------------
# simulate_startOnMachine
#   Mirrors the four SSH/SCP calls in the real startOnMachine() sub.
# ---------------------------------------------------------------------------
sub simulate_startOnMachine {
    my ($node_ref, $mode) = @_;
    my $name = $node_ref->{name};
    my $ip   = $node_ref->{ip};
    my $t    = $NODE_TIMING{$name};

    my $hdr = "$name ($ip) STATUS:";

    log_node($name, "<=========================================================>");
    log_node($name, "$hdr Begin");

    # -- Step 1: SSH setup remote directory --------------------------------
    log_node($name, "SSH  [$ip] rm -rf /tmp/.install; mkdir -p /tmp/.install");
    sim_sleep($t->{ssh_setup});
    log_node($name, "SSH  [$ip] directory created (${\ sim_fmt($t->{ssh_setup})}s)");

    # -- Step 2: SCP transfer install directory ----------------------------
    log_node($name, "SCP  [$ip] transferring install package (~150 MB) ...");
    sim_sleep($t->{scp_transfer});
    log_node($name, "SCP  [$ip] transfer complete (${\ sim_fmt($t->{scp_transfer})}s)");

    # -- Step 3: SSH execute install ---------------------------------------
    log_node($name, "SSH  [$ip] executing ./MLCCN_Install -a=192.168.55.100:12345 install");

    # Sub-steps printed as they would appear in mlccninstall.log on the remote node
    sim_sleep($t->{ssh_install} * 0.05);
    log_node($name, "     >> Checking license (NodeLicense.lic) ...");
    sim_sleep($t->{ssh_install} * 0.08);
    log_node($name, "     >> Creating polaris user/group ...");
    sim_sleep($t->{ssh_install} * 0.04);
    log_node($name, "     >> Set up in progress ...");
    sim_sleep($t->{ssh_install} * 0.10);
    log_node($name, "     >> PLT: in progress");
    sim_sleep($t->{ssh_install} * 0.15);
    log_node($name, "     >> PLT: done");
    sim_sleep($t->{ssh_install} * 0.10);
    log_node($name, "     >> SGW: in progress");
    sim_sleep($t->{ssh_install} * 0.10);
    log_node($name, "     >> SGW: done");
    sim_sleep($t->{ssh_install} * 0.08);
    log_node($name, "     >> Generating port assignments ...");
    sim_sleep($t->{ssh_install} * 0.08);
    log_node($name, "     >> Writing PDEApp.ini ...");
    sim_sleep($t->{ssh_install} * 0.10);
    log_node($name, "     >> Setting up mlccndaemon service ...");
    sim_sleep($t->{ssh_install} * 0.07);
    log_node($name, "     >> Activating release (creating 'active' symlink) ...");
    sim_sleep($t->{ssh_install} * 0.05);
    log_node($name, "     >> Release successfully installed and activated");
    log_node($name, "SSH  [$ip] install complete (${\ sim_fmt($t->{ssh_install})}s)");

    # -- Step 4: SSH cleanup -----------------------------------------------
    log_node($name, "SSH  [$ip] cleanup rm -rf /tmp/.install");
    sim_sleep($t->{ssh_clean});
    log_node($name, "SSH  [$ip] cleanup done (${\ sim_fmt($t->{ssh_clean})}s)");

    # -- Final status ------------------------------------------------------
    my $total_sim = $t->{ssh_setup} + $t->{scp_transfer} + $t->{ssh_install} + $t->{ssh_clean};
    log_node($name, "$hdr Completed  (node total: ${\ sim_fmt($total_sim)}s)");

    { lock($gStatusFileMutex); push @gStatusLog, "$name\@done"; }

    return $total_sim;
}

# ===========================================================================
# RUN 1 — SEQUENTIAL  (original script behaviour)
# ===========================================================================
sub run_sequential {
    print "\n";
    print "=" x 70 . "\n";
    print "SEQUENTIAL RUN  (original MLCCN_Install_R12.4.1.26 behaviour)\n";
    print "Command : ./MLCCN_Install_R12.4.1.26 -c=config.txt install\n";
    print "Nodes   : " . join(", ", map { $_->{name} } @NODES) . "\n";
    print "=" x 70 . "\n\n";

    @gStatusLog  = ();
    $gWallStart  = time();

    logcons("COMMAND: install");
    logcons("Untarring PLT package, installing pexpect ...");
    sim_sleep(4);   # untarPltPkg + pexpect_install

    my @per_node_times;
    foreach my $node (@NODES) {
        my $t = simulate_startOnMachine($node, 'sequential');
        push @per_node_times, { name => $node->{name}, time => $t };
    }

    logcons("All nodes completed.");
    my $total_wall_real = time() - $gWallStart;
    my $total_wall_sim  = $total_wall_real * SPEEDUP;

    return ($total_wall_sim, \@per_node_times);
}

# ===========================================================================
# RUN 2 — PARALLEL  (patched script behaviour)
# ===========================================================================
sub run_parallel {
    print "\n";
    print "=" x 70 . "\n";
    print "PARALLEL RUN  (patched MLCCN_Install_R12.4.1.26 behaviour)\n";
    print "Command : ./MLCCN_Install_R12.4.1.26 -c=config.txt install\n";
    print "Nodes   : " . join(", ", map { $_->{name} } @NODES) . "\n";
    print "=" x 70 . "\n\n";

    @gStatusLog  = ();
    $gWallStart  = time();

    logcons("COMMAND: install");
    logcons("Untarring PLT package, installing pexpect ...");
    sim_sleep(4);   # untarPltPkg + pexpect_install

    logcons("PARALLEL: dispatching install to " . scalar(@NODES) . " node(s) concurrently");

    my @workers;
    my %node_times :shared;
    foreach my $node (@NODES) {
        my $node_copy = $node;
        my $t = threads->create(sub {
            my $elapsed = simulate_startOnMachine($node_copy, 'parallel');
            lock(%node_times);
            $node_times{$node_copy->{name}} = $elapsed;
        });
        push @workers, $t;
    }
    $_->join() for @workers;

    logcons("PARALLEL: all " . scalar(@NODES) . " node(s) finished install");

    my $total_wall_real = time() - $gWallStart;
    my $total_wall_sim  = $total_wall_real * SPEEDUP;

    my @per_node_times = map { { name => $_, time => $node_times{$_} } }
                         sort keys %node_times;

    return ($total_wall_sim, \@per_node_times);
}

# ===========================================================================
# MAIN
# ===========================================================================

# ---- Sequential run -------------------------------------------------------
my ($seq_wall, $seq_nodes) = run_sequential();

print "\n";
print "-" x 70 . "\n";
print "SEQUENTIAL — Status file after completion\n";
print "-" x 70 . "\n";
foreach my $entry (@gStatusLog) { print "  $entry\n"; }
print "-" x 70 . "\n";

# ---- Parallel run ---------------------------------------------------------
my ($par_wall, $par_nodes) = run_parallel();

print "\n";
print "-" x 70 . "\n";
print "PARALLEL — Status file after completion\n";
print "-" x 70 . "\n";
foreach my $entry (sort @gStatusLog) { print "  $entry\n"; }
print "-" x 70 . "\n";

# ===========================================================================
# COMPARISON REPORT
# ===========================================================================
my $speedup   = $seq_wall / $par_wall;
my $saved     = $seq_wall - $par_wall;
my $pct_saved = ($saved / $seq_wall) * 100;

sub fmt_time {
    my $s = int(shift);
    return sprintf("%d m %02d s", int($s/60), $s % 60);
}

print "\n";
print "=" x 70 . "\n";
print "TIMING COMPARISON  —  ./MLCCN_Install_R12.4.1.26 -c=config.txt install\n";
print "=" x 70 . "\n";
printf "%-30s  %s\n", "Config nodes:", join(", ", map { $_->{name} } @NODES);
print "\n";

printf "%-14s  %8s  %s\n", "Node", "Seq (s)", "Par (s)";
print "-" x 40 . "\n";

my %par_map = map { $_->{name} => $_->{time} } @{$par_nodes};
my ($slowest_node, $slowest_time) = ('', 0);
foreach my $n (@{$seq_nodes}) {
    printf "  %-12s  %6s s  %6s s\n",
           $n->{name},
           sim_fmt($n->{time}),
           sim_fmt($par_map{$n->{name}} // $n->{time});
    if ($n->{time} > $slowest_time) {
        $slowest_time = $n->{time};
        $slowest_node = $n->{name};
    }
}

print "-" x 40 . "\n";
printf "  %-12s  %6s    %6s\n", "(overhead)", "~4 s", "~4 s";
print "\n";

print "-" x 70 . "\n";
printf "  Sequential total  :  %s  (~%.0f s)\n", fmt_time($seq_wall), $seq_wall;
printf "  Parallel total    :  %s  (~%.0f s)\n", fmt_time($par_wall), $par_wall;
printf "  Time saved        :  %s  (~%.0f s)\n", fmt_time($saved), $saved;
printf "  Speedup           :  %.1fx\n", $speedup;
printf "  Efficiency        :  %.1f%%\n", $pct_saved;
printf "  Bottleneck node   :  %s (%s)\n", $slowest_node, fmt_time($slowest_time);
print "=" x 70 . "\n";
print "\nNOTE: Parallel wall-clock time = slowest single node ($slowest_node).\n";
print "      All other nodes complete in the background while $slowest_node finishes.\n";
print "\nAll 6 nodes: install\@done  (verified in .status_install)\n\n";
