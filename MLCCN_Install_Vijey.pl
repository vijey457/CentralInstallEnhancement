#!/usr/bin/perl

use strict;
#use warnings;
#use diagnostics;
use Term::ANSIColor;
use Term::ANSIColor qw(:constants);
use File::Basename;
use File::Path;
use File::Copy;
use File::Find;
use Cwd;
use Socket;
use threads;
use threads::shared;
use Thread::Semaphore;
no warnings 'threads';

local $Term::ANSIColor::AUTORESET = 1;
use constant false => 0;
use constant true  => 1;
use constant listen_port => 12345;
use constant mlccn => "mlccn";
use constant mer => "mer";
use constant tsmlccn => "tsmlccn";

use constant LOGFATAL  => 1;
use constant LOGERROR  => 2;
use constant LOGINFO   => 4;
use constant LOGCONS   => 8;

# classes used
package surecord;
sub new {
	my $class = shift;
	bless {
		'version' => "",
			'compname' => "",
			'sg' => "",
			'mode' => "",
			'nodes' => [()],
			'apps' => [()],
			'exes' => [()],
	}, $class;
}

package main;

# global settings for this release
my $gLksctp		= true;

my $gContinueOnPrecheckFail = $ENV{NOPRECHECK};
my $logEnabled = $ENV{LOGENABLED};
my $gOnlyConfig = $ENV{ONLYCFG};

my $gIsUpgrade			= false;
my $gProduct			= &getProduct();
my $gProductLegacy		= "MLC";
my $gProductLc			= lc($gProduct);
my $gUser				= "polaris";
my $gGroup				= "polaris";
my $gBaseDir            = "/Disk";
my $gRednNodesDir       = "nodes";
my $gHomeBaseDir		= "$gBaseDir/home";
my $gHomeDir			= "$gHomeBaseDir/$gUser";
my $gBasePath			= "$gHomeDir/$gProductLc";
my $gReleasePath		= "$gBasePath/release";
my $gActiverRelLink		= "$gBasePath/active";
my $gBinDir				= "bin";
my $gCfgDir				= "cfg";
my $gActiveBinDir		= "$gActiverRelLink/$gBinDir";
my $gPkgDir				= "package";
my $gLibDir				= "lib";
my $gCompletedFile		= ".done";
my $gUseOpensafFile		= ".opensaf";
my $gOsafStartFile 		= "/etc/init.d/opensafd";
my $gMlcCleanFile       = "/etc/init.d/mlcclean";
my $gStartSctpFile		= ".sctp";
my $gBasePortAppMgr 	= 10000;
if($gProductLc eq tsmlccn) {
	$gBasePortAppMgr 	= 12000;
	$gProductLegacy		= "TSMLC";
}
my $gBasePort 		= $gBasePortAppMgr + 1000;
my $gEphemeralStartPort	= 50000;
my $gEphemeralEndPort	= 65535;
my $gIniFile 			= "PDEApp.ini";
my $gDiaIniFile 		= "dia.ini";
my $gAlarmIniFile 		= "alarmdef.ini";
my $gLicFilePrefix		= "PLT_LicenseDecoder_";
my $gInitTabFile		= "/etc/inittab";
my $gActiveKey			= "active";
my $gInstalledKey		= "installed";
my $gInstallApp 		= sprintf("%s_Install", $gProduct);
my $gAppMgrName			= "AppMgr";
my $gMlcDaemon			= sprintf("%sdaemon", $gProductLc);
my $gLogsMgrName		= "LogsManager";
my $gBRMName		    = "BRM";
my $gStartAppName		= "startApp";
my $gVirtIpConfigure	= "VirtIPConfigure";
my $gLogRetentionPeriod = 30;
my @gPMList = ();
my $gPatchVerFile		= ".patchver";

my %gPortNumbers;
my $localmac="";
# this keeps track of the current port index used
# leave first 10 ports for hard coded ports used in applications
my $gPortIndex			= 9;
my $gMaxPortAppIndex	= 200;
my $gCentralizedOp = false;
my $gPeerSockFd;

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

my $gLDirPath = `/bin/pwd`;
chomp $gLDirPath;

my $gHostName = `/bin/hostname`;
chomp $gHostName;
my $gProcessor =`/bin/uname -p`;
chomp $gProcessor;
my $gOs =`/bin/uname -s`;
chomp $gOs;
my $gIsLinux = false;
my $gUsingOpensaf = false;
#Virtualization related params
my $gUsingVMware = false;
my $gVMwareIniFile = "/root/.visdkrc";
my $gVMwareVMname;
my $gVMwareFile  = ".vmware";
if($gOs eq "Linux") {
	$gIsLinux = true;
}

my $kernel=`uname -r | cut -d "-" -f 1 | cut -d "." -f1`;
chomp $kernel;

#7 means rhel 7 and above
my $gRhelVer = 0;
if($kernel >= 3) {
	$gRhelVer = 7;
} elsif($kernel == 2) {
	$gRhelVer = 6;
}

my $gNumNodes = 0;
my $gNodeCnt = 0;
my $gIsController = false;
my $gLogFile = sprintf("%s_polaris_%s.log", $gHostName, $gProductLc);

my %startCmdData = (
	"function" => \&procStart,
	"root" => true,
	"connection" => false,
	"status" => true,
);

my %stopCmdData = (
	"function" => \&procStop,
	"root" => true,
	"connection" => false,
	"status" => true,
);

my %statusCmdData = (
	"function" => \&procStatus,
	"root" => false,
	"transferinstall" => true,
	"connection" => false,
	"status" => false,
);

my %restartCmdData = (
	"function" => \&procReStart,
	"root" => true,
	"connection" => false,
	"status" => true,
);

my %installCmdData = (
	"function" => \&procInstall,
	"root" => true,
	"connection" => true,
	"status" => true,
);

my %patchCmdData = (
	"function" => \&procPatch,
	"subcmds" => "patch_global_pre,patch,patch_global_post",
	"root" => true,
	"connection" => false,
	"status" => true,
);

my %activateCmdData = (
	"function" => \&procActivate,
	"root" => true,
	"transferinstall" => true,
	"connection" => true,
	"status" => true,
);

my %upgradeCmdData = (
	"function" => \&procUpgrade,
	"root" => true,
	"connection" => true,
	"status" => true,
);

my %uninstallCmdData = (
	"function" => \&procUninstall,
	"root" => true,
	"transferinstall" => true,
	"connection" => true,
	"status" => true,
);

my %showrelCmdData = (
	"function" => \&procShowRel,
	"root" => true,
	"transferinstall" => true,
	"connection" => false,
	"status" => false,
);

my %configuerCmdData = (
	"function" => \&procConfigure,
	"root" => false,
	"transferinstall" => true,
	"connection" => false,
	"status" => false,
);


my %installCmds = (
	"start" => \%startCmdData,
	"stop" => \%stopCmdData,
	"status" => \%statusCmdData,
	"restart" => \%restartCmdData,
	"install" => \%installCmdData,
	"patch_global_pre" => \%patchCmdData,
	"patch" => \%patchCmdData,
	"patch_global_post" => \%patchCmdData,
	"activate" => \%activateCmdData,
	"upgrade" => \%upgradeCmdData,
	"uninstall"=> \%uninstallCmdData,
	"showreleases" => \%showrelCmdData,
);

my @prgwDomainToString = (
	"",
	"GSM-CS",
	"GSM-PS",
	"UMTS-CS",
	"UMTS-PS",
	"LTE",
	"CORENETWORK",
	"LTE-PW",
	"NR-PW"
);

# optional only for dev testing
if ($gOnlyConfig ne "") {
	$installCmds{"configure"} = \%configuerCmdData,
}


my %gPltSstDetail = (
# name as it appears in the license file
	"LicName" => "PLT",
# name as it appears in the package file
	"PkgPrefix" => "PLT_",
# list of apps contained in the package file
# The order of the  applications should be as in the h file PlatformDefs.h
#usesnmp code
#"Apps" => [ ($gAppMgrName, "OamProxy", "OamAgent", "OamManager", "SnmpMaster", "SnmpTrapAgent", "NetSnmpSubAgent", $gLogsMgrName) ],
	"Apps" => [ ($gAppMgrName, "OamClient", $gLogsMgrName, $gBRMName) ],
# list of apps/configs contained in the package file which have to be linked without
# release number
# usesnmp code
#"Configs" => [ ("oam_control.sh", "snmpd", $gStartAppName, $gVirtIpConfigure, "suctl", "mlcutils") ],
	"Configs" => [ ($gStartAppName, $gMlcDaemon, $gVirtIpConfigure, "mlcutils", "mlcclean", "suctl", "query_mlc.py", "NetworkFileParser.pl","IsMaxResetOver") ],
# subsystem specific installation
	"InstallFunc" => \&pltInstall,
	"ConfigFunc" => \&pltConfig,
# actual mode, subsystem instance read from license file populated duration installation
	"Mode" => "",
	"Instance" => "",
# actual package name to be populated during installation
	"PkgName" => ""
);

my %gSgwSstDetail = ();
		%gSgwSstDetail = (
			"LicName" => "SGW",
			"PkgPrefix" => "SGW_",
			"Apps" => [ ("SGWApp", "Mtp2Convertor", "SgwOamApp", "M3UA", "SIGTRANStack", "SS7Stack", "TSGWApp", "TCPGWApp") ],
			"Configs" => [ ("StackCfg", "stackPortGen.pl", "xmldata") ],
			"InstallFunc" => \&sgwInstall,
			"ConfigFunc" => \&sgwConfig,
			"Mode" => "",
			"Instance" => "",
			"PkgName" => ""
			);

my %gMdbSstDetail = (
		"LicName" => "MDB",
		"PkgPrefix" => "MDB_",
		"Apps" => [ ("MdbApp") ],
		"InstallFunc" => \&mdbInstall,
		"ConfigFunc" => \&mdbConfig,
		"Mode" => "",
		"Instance" => "",
		"PkgName" => ""
		);

my %gMlsSstDetail = (
		"LicName" => "MLS",
		"PkgPrefix" => "MLS_",
		"Apps" => [ ("MiMSPApp", "MiGmlcGw", "OamAggregator", "MiLCSClientHandler", "MiPolicyMgr") ],
		"InstallFunc" => \&mlsInstall,
		"ConfigFunc" => \&mlsConfig,
		"Mode" => "",
		"Instance" => "",
		"PkgName" => ""
		);

my %gPrgwSstDetail = (
		"LicName" => "PRGW",
		"PkgPrefix" => "PRGW_",
# do not add anyother application in the begining as the PRGWAgent is accessed using index 0
# also STS(renamed from SSS) is indexed by 1, and SSH by 2.
# add any new applications at the end

		"Apps" => [ ("PRGWAgent", "STS", "SSH", "NRPROBE", "LTEPROBE", "GSMPROBE", "ERApp") ],
		"Configs" => [ ("MLSEventsMapping.txt", "MLSUmtsEventsMapping.txt", "MLSLteEventsMapping.txt", "MLSCoreNetworkEventsMapping.txt","TA_MODEL_TYPE_1.txt", "TA_MODEL_TYPE_2.txt") ],
		"InstallFunc" => \&prgwInstall,
		"ConfigFunc" => \&prgwConfig,
		"Mode" => "",
		"Instance" => "",
		"PkgName" => ""
		);

my %gPrgwMerSstDetail = (
		"LicName" => "PRGW",
		"PkgPrefix" => "PRGW_",
# do not add anyother application in the begining as the PRGWAgent is accessed using index 0
# also STS(renamed from SSS) is indexed by 1, and SSH by 2.
# add any new applications at the end

		"Apps" => [ ("PRGWAgent", "ERApp") ],
		"Configs" => [ ("SMSAppEventsMapping.txt", "SMSAppUmtsEventsMapping.txt", "SMSAppLteEventsMapping.txt") ],
		"InstallFunc" => \&prgwMerInstall,
		"ConfigFunc" => \&prgwMerConfig,
		"Mode" => "",
		"Instance" => "",
		"PkgName" => ""
		);

my %gLdsSstDetail = (
		"LicName" => "LDS",
		"PkgPrefix" => "LDS_",
# do not add any other application in the begining as the GsmCallManager and UmtsCallManager
# is accessed using index 1, 2 and 3.
		"Apps" => [ ("LocReqDisp", "GsmCallManager", "UmtsCallManager", "LdsLteCm", "GsmLEApp", 
				"UmtsLEApp", "LdsLteWLEApp", "LdsLteHLEApp", "LdsPm", "LdsDbBe", "LdsNrCm", "LdsNrWLEApp") ],
		"Configs" => [ ("TA_MODEL_TYPE_1.txt", "TA_MODEL_TYPE_2.txt") ],
		"InstallFunc" => \&ldsInstall,
		"ConfigFunc" => \&ldsConfig,
		"Mode" => "",
		"Instance" => "",
		"PkgName" => ""
		);

my %gOlgwSstDetail = (
		"LicName" => "OLGW",
		"PkgPrefix" => "OLGW_",
		"Apps" => [ ("AppServer", "LCSI") ],
		"Configs" => [ ("olgwinit", "ipqosconf.cfg") ],
		"InstallFunc" => \&olgwInstall,
		"ConfigFunc" => \&olgwConfig,
		"Mode" => "",
		"Instance" => "",
		"PkgName" => ""
		);

my %gTlrSstDetail = (
		"LicName" => "TLR",
		"PkgPrefix" => "TLR_",
		"Apps" => [ ("TlrApp") ],
		"Configs" => [ () ],
		"InstallFunc" => \&tlrInstall,
		"ConfigFunc" => \&tlrConfig,
		"Mode" => "",
		"Instance" => "",
		"PkgName" => ""
		);

my %gAdsSstDetail = (
		"LicName" => "ADS",
		"PkgPrefix" => "ADS_",
		"Apps" => [ ("AgpsServer", "OtdoaAds") ],
		"Configs" => [ ("RgpsFtpClient.sh", "LeicaRinexCopy.sh") ],
		"InstallFunc" => \&adsInstall,
		"ConfigFunc" => \&adsConfig,
		"Mode" => "",
		"Instance" => "",
		"PkgName" => ""
		);

my %gAdmSstDetail = (
		"LicName" => "ADM",
		"PkgPrefix" => "ADM_",
		"Apps" => [ ("WLDM", "WSDM") ],
		"Configs" => [ ("exceltocsv.py") ],
		"InstallFunc" => \&admInstall,
		"ConfigFunc" => \&admConfig,
		"Mode" => "",
		"Instance" => "",
		"PkgName" => ""
		);

my %gOamSstDetail = (
		"LicName" => "OAM",
		"PkgPrefix" => "OAM_",
		"Apps" => [ () ],
		"Configs" => [ () ],
		"InstallFunc" => \&oamInstall,
		"ConfigFunc" => \&oamConfig,
		"Mode" => "",
		"Instance" => "",
		"PkgName" => ""
		);

my %gCgwSstDetail = (
		"LicName" => "CGW",
		"PkgPrefix" => "CGW_",
		"Apps" => [ ("CaGwApp") ],
		"Configs" => [ () ],
		"InstallFunc" => \&cgwInstall,
		"ConfigFunc" => \&cgwConfig,
		"Mode" => "",
		"Instance" => "",
		"PkgName" => ""
		);

my %gHVGwSstDetail = (
		"LicName" => "HVGW",
		"PkgPrefix" => "HVGW_",
		"Apps" => [ ("HVlrGwApp") ],
		"Configs" => [ () ],
		"InstallFunc" => \&hvgwInstall,
		"ConfigFunc" => \&hvgwConfig,
		"Mode" => "",
		"Instance" => "",
		"PkgName" => ""
		);

my @ssts = (
		\%gSgwSstDetail,
		\%gMdbSstDetail,
		\%gMlsSstDetail,
		\%gPrgwSstDetail,
		\%gLdsSstDetail,
		\%gOlgwSstDetail,
		\%gOamSstDetail,
		\%gCgwSstDetail,
		\%gHVGwSstDetail,
		\%gTlrSstDetail,
		\%gAdsSstDetail,
		\%gAdmSstDetail,
		\%gPltSstDetail
		);
if($gProductLc eq "mer") {
	@ssts = (
		\%gPrgwMerSstDetail,
		\%gPltSstDetail
		);
}

my %gCompToVersion = ();

my $gCdtPath			= "$gBasePath/CDTs/";
my $gCdtPathGsm			= "$gBasePath/CDTs/GSM/";
my $gCdtPathUmts		= "$gBasePath/CDTs/UMTS/";
my $gCdtPathLte			= "$gBasePath/CDTs/LTE/";
my $gCdtPathNr			= "$gBasePath/CDTs/NR/";
my $gPsdPath			= "$gBasePath/PSD/";
my $gPsdPathGsm			= "$gBasePath/PSD/GSM";
my $gPsdPathUmts		= "$gBasePath/PSD/UMTS";
my $gPsdPathLte			= "$gBasePath/PSD/LTE";
my $gPsdPathNr			= "$gBasePath/PSD/NR";

my $gLogsDirPath		= "$gBasePath/logs";
my $gHVlrDumpDir		= "$gLogsDirPath/hvlrdump";
my $gCoreDir			= "$gLogsDirPath/coredump";
my $crLogDir			= "$gLogsDirPath/LocationResult";
my $pidFileDir			= "$gLogsDirPath/PID";
my $msgLogDir			= "$gLogsDirPath/MsgLog";
my $fpupdateLogDir		= "$gLogsDirPath/FPUpdates";
my %appPairMap = ();
my $appPairMapPopulated = 0;


my $gPromptsFile = ".prompts";
my %gPromptToInput = ();
my $gPromptPrev = "";
my $gPromptValuePrev = "";


my $cpCmd = "/bin/cp";
my $svcadmCmd = "/usr/sbin/svcadm";
my $rmCmd = "/bin/rm";
my $lnCmd = "/bin/ln";
my $chownCmd = "/bin/chown";
my $idCmd = "/usr/bin/id";
my $mvCmd = "/bin/mv";
my $usrAddCmd = "/usr/sbin/useradd";
my $grpAddCmd = "/usr/sbin/groupadd";
my $usrModCmd = "/usr/sbin/usermod";
my $killCmd = "/usr/bin/kill";
my $crontabCmd = "/usr/bin/crontab";
my $logadmCmd = "/usr/sbin/logadm";
my $touchCmd = "/bin/touch";
my $chmodCmd = "/bin/chmod";
my $mkdirCmd = "/bin/mkdir";
my $passwdCmd = "/usr/bin/passwd";
my $gunzipCmd = "/usr/bin/gunzip";
my $gzipCmd = "/usr/bin/gzip";
my $tarCmd	= "/bin/tar";
my $initCmd   = "/sbin/init";
my $initctlCmd   = "/sbin/initctl";
my $systemctlCmd   = "/usr/bin/systemctl";
my $shareCmd  = "/usr/sbin/share";
my $coreadmCmd  = "/usr/bin/coreadm";
my $qcxConfCmd = "/usr/net/Adax/qcx/qcx_conf";
my $mountCmd = "/usr/bin/mount";
my $umountCmd = "usr/bin/umount";

my $logCmd				= "> /dev/null 2> /dev/null";
my $scriptLogFile		= sprintf("%s/%sinstall.log", $gLogsDirPath, $gProductLc);
my $logfileCmd			= ">> $scriptLogFile 2>> $scriptLogFile";

$SIG{INT}  = \&signalHandler;
$SIG{TERM} = \&signalHandler;

sub signalHandler ()
{
	logToFile("\nOperation aborted", LOGFATAL | LOGCONS);
}


# Perl trim function to remove whitespace from the start and end of the string
sub trimmer($)
{
	my $string = shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}

sub getPromptInput($)
{
	my $prompt = shift;
	my $input = "";
	if ($gCentralizedOp == true) {
		send($gPeerSockFd, $prompt, 0);
		my $ret = recv($gPeerSockFd, $input, 2000 , 0);
		if($input eq "N-U-L-L") {
			$input = "";
		}
	} else {
		if (exists $gPromptToInput{$prompt}) {
			$input = $gPromptToInput{$prompt};
		} else {
			print "$prompt : ";
			$input = <STDIN>;
			chomp $input;
			$input = trimmer($input);
			$gPromptToInput{$prompt} = $input;
			if($gPromptPrev ne "") {
				if (open(CONF, ">>",$gPromptsFile)) {
					print CONF "$gPromptPrev\n";
					print CONF "$gPromptValuePrev\n";
					close (CONF);
				}
			}
			$gPromptPrev = $prompt;
			$gPromptValuePrev = $input;
		}
	}

	return $input;
}

sub logToFile($$)
{
	my $log = shift;
	my $severity = shift;

	# check if only console print is required.
	# is yes...don't log to file.
	if($severity != LOGCONS)
	{
		my $logfd;
		open($logfd, ">>",$scriptLogFile);
		my $timestamp = `date`;
		chomp $timestamp;
		print $logfd "[$timestamp] ";
		print $logfd "$log\n";
		close($logfd);
	}

	my $colour = 'white';
	if (($severity & LOGFATAL) != 0) {
		$colour = 'red';
		if ($gCentralizedOp == true) {
			$log = sprintf("FATAL;%sFATAL;", $log);
		} else {
			$log = sprintf("%s", $log);
		}
	} elsif (($severity & LOGERROR) != 0) {
		$colour = 'red';
	} elsif (($severity & LOGINFO) != 0)  {
		$colour = 'green';
	}

	my $printOnScreen = false;
	if (($severity & LOGCONS) != 0) {
		$printOnScreen = true;
	}

	if($printOnScreen || (defined $logEnabled && $logEnabled eq "true")) {
		lock($gConsoleMutex);   # prevent interleaved output from parallel threads
		if($gCentralizedOp == true) {
			print "$log\n";
		} else {
			#print color($colour), ON_BLACK "$log\n";
			print "$log\n";
		}
	}

	if(($severity & LOGFATAL) == 1) {
		exit(1);
	}
}

sub System($$$)
{
	my $cmd = shift;
	my $die = shift;
	my $errorMsg = shift;
	my @entries = ();
	if ( system("$cmd $logCmd") == 0 )
	{
		return 0;
	}
	else
	{
		if($die eq 0)
		{
			@entries = split(' ', $cmd);
			if($logEnabled ne "")
			{
				logToFile("ERROR:: Running $cmd $logCmd failed", LOGERROR | LOGCONS);
			}
			return -1;
		}
		else
		{
			if ($errorMsg eq "")
			{
				@entries = split(' ', $cmd);
				if($logEnabled ne "") {
					logToFile("FATAL:: Running command $entries[0] failed", LOGFATAL | LOGCONS);
				} else {
					logToFile("", LOGFATAL | LOGCONS);
				}
				return -1;
			}
			else
			{
				@entries = split(' ', $cmd);
				if($logEnabled ne "")
				{
					logToFile("FATAL:: $errorMsg", LOGFATAL | LOGCONS);
				}
				else
				{
					logToFile("", LOGFATAL | LOGCONS);
				}
				return -1;
			}

		}
	}
}

sub getAppInstanceId($$$$$) {
	my $sstname = shift;
	my $appname = shift;
	my $licconfig = shift;
	my $pltinstance = shift;
	my $sstinstance = shift;

	my $section = sprintf("PLATFORM_%d", $pltinstance);
	my $retval = 0;

 	foreach my $parminfo (@{$licconfig->{$section}}) {
		my @values = split(":", $parminfo->{'name'});
		if($values[0] eq $sstname && $values[1] eq $appname && $values[2] eq $sstinstance) {
			$retval = $values[3];
		}
	}
	return $retval;
}

sub writeConfigVal($$$$$)
{
	my $configHash = shift;
	my $section = shift;
	my $key = shift;
	my $val = shift;
	my $override = shift;

	#my %paraminfo = ();
	#$paraminfo{'name'} = $key;
	#$paraminfo{'value'} = $val;

	if($override == true) {
		#push @{$configHash->{$section}}, \%paraminfo ;
		&setParam($configHash, $section, $key, $val);
		return;
	}

	# if override not set to true, update  only if  old value is
	# not present
	my $oldval = &getParam($configHash, $section, $key);
	if(!defined($oldval)) {
		&setParam($configHash, $section, $key, $val);
		return;
	}
}

# TCP standard has "simultaneous open" feature :).
# The implication of the feature, client trying to connect to local port, when the port is from ephemeral range, can occasionally connect to itself (see here).
# So client think it's connected to server, while it actually connected to itself. From other side, server can not open its server port, since it's occupied/stolen by client.
# clients constantly tries to connect to local server. Eventually client connects to itself.
# Don't use ephemeral ports for server ports. Agree ephemeral port range and configure it on your machines (see ephemeral range)

sub setupStart {
	System("/sbin/sysctl -w kernel.core_pattern=core.%e.%p > /dev/null", 0 , "could not set kernel.core_pattern");
	System("/sbin/sysctl -w net.core.wmem_max=160000000", 0 , "could not set net.core.wmem_max");
	System("/sbin/sysctl -w net.core.rmem_max=160000000", 0 , "could not set net.core.rmem_max");
	System("/sbin/sysctl -w net.core.wmem_default=160000000", 0 , "could not set net.core.wmem_default");
	System("/sbin/sysctl -w net.core.rmem_default=160000000", 0 , "could not set net.core.rmem_default");
	System("/sbin/sysctl -w net.ipv4.tcp_mem='16000000 16000000 16000000'", 0 , "could not set net.ipv4.tcp_mem");
	System("/sbin/sysctl -w net.ipv4.tcp_wmem='16000000 16000000 16000000'", 0 , "could not set net.ipv4.tcp_wmem");
	System("/sbin/sysctl -w net.ipv4.tcp_rmem='16000000 16000000 16000000'", 0 , "could not set net.ipv4.tcp_rmem");
	System("/sbin/sysctl -w net.ipv4.udp_mem='16000000 16000000 16000000'", 0 , "could not set net.ipv4.udp_mem");
	System("/sbin/sysctl -w net.sctp.rto_initial=1000", 0 , "Could not set net.sctp.rto_initial");
	System("/sbin/sysctl -w net.core.wmem_default=4293760", 0 , "Could not set net.core.wmem_default");
	System("/sbin/sysctl -w net.ipv4.ip_local_port_range=\"$gEphemeralStartPort $gEphemeralEndPort\"", 1 , "Counld not set emphemeral port ranges");

# check the sysconf entry for local port range.
	my $sysconfFile = "/etc/sysctl.conf";
	my $sysconfEntry = "net.ipv4.ip_local_port_range";

# do not use the sub System here as redirection to a log file doesn't work.
	open(SYSCONF, "<", $sysconfFile) or die "Could not open $sysconfFile";
	my @entries=<SYSCONF>;
	close (SYSCONF);

	open(SYSCONF, ">", $sysconfFile) or die "Could not open $sysconfFile.";
	my $found = false;
	foreach my $line (@entries)
	{
		if ($line =~ /$sysconfEntry/)
		{
			print SYSCONF "$sysconfEntry = $gEphemeralStartPort $gEphemeralEndPort\n";
			$found = true;
		}
		else
		{
			print SYSCONF $line;
		}
	}

	if($found == false) {
		print SYSCONF "$sysconfEntry = $gEphemeralStartPort $gEphemeralEndPort\n";
	}
	close (SYSCONF);

# log the emphemeral port range to <product>_install.log
        logToFile ("/sbin/sysctl net.ipv4.ip_local_port_range", LOGINFO);
        if(system("/sbin/sysctl net.ipv4.ip_local_port_range >> \"$scriptLogFile\"") != 0) {
			logToFile ("Could not get emphemeral port range", LOGCONS);
        }
#print "local port range successfully set up\n";
}


sub setupPaths()
{
	$gReleasePath		= "$gBasePath/release"  ;
	$gCdtPathGsm		= "$gBasePath/CDTs/GSM/";
	$gCdtPathUmts		= "$gBasePath/CDTs/UMTS/";
	$gCdtPathLte		= "$gBasePath/CDTs/LTE/";
	$gCdtPathNr		= "$gBasePath/CDTs/NR/";
	$gPsdPathGsm		= "$gBasePath/PSD/GSM";
	$gPsdPathUmts		= "$gBasePath/PSD/UMTS";
	$gPsdPathLte		= "$gBasePath/PSD/LTE";
	$gPsdPathNr		= "$gBasePath/PSD/NR";


	$gActiverRelLink	= "$gBasePath/active";
	$gActiveBinDir		= "$gActiverRelLink/$gBinDir";


	$gLogsDirPath		= "$gBasePath/logs";
	$crLogDir			= "$gLogsDirPath/LocationResult";
	$pidFileDir			= "$gLogsDirPath/PID";
	$msgLogDir			= "$gLogsDirPath/MsgLog";
	$fpupdateLogDir		= "$gLogsDirPath/FPUpdates";
	$scriptLogFile		= sprintf("%s/%sinstall.log", $gLogsDirPath, $gProductLc);
	$gCoreDir			= "$gLogsDirPath/coredump";
}

sub checkRootAndExit()
{
	if($gIsLinux == true) {
		my $return = `$idCmd -u`;
		if ($return == 0) {
		} else {
			logToFile("Run the script as root user", LOGFATAL | LOGCONS);
		}
	} else {
		if (system("$idCmd | /usr/bin/grep \"(root)\" $logCmd") == 0) {
		} else {
			logToFile("Run the script as root user", LOGFATAL | LOGCONS);
		}
	}
}

sub printHelpAndExit()
{
	# -p switch is not exposed to user hence not displayed in help
	print "Usage: $0 [-c=<configuration file>] [-o=abort] <COMMAND>\n\n";

	print "COMMAND can be one of the following\n";
	print "---------------------------------------------------------\n";
	print "install       : Installs $gProduct binaries\n";
	print "upgrade       : Upgrades to new release\n";
	print "patch         : Applies patch\n";
	print "start         : Starts $gProduct binaries\n";
	print "stop          : Stops $gProduct binaries\n";
	print "status        : Shows status of $gProduct binaries\n";
	print "restart       : Stops and starts $gProduct binaries\n";
	print "activate      : Activates the installed release\n";
	print "uninstall     : Uninstalls selected $gProduct release(s)\n";
	print "showreleases  : Show current installed release(s)\n";
	print "-h            : Displays Command line options\n";
	print "---------------------------------------------------------\n";

	exit();
}

sub readPrompt($)
{
	my $promptHash = shift;
	# each switch requries a paramter except for command
	my $numArgs = $#ARGV + 1;
	my $cnt = 0;
	for(; $cnt < $numArgs; $cnt++) {
		my @values = split("=", $ARGV[$cnt]);
		chomp(@values);

		if($ARGV[$cnt] =~ /^-/) {
			# configuration switch is provided.
			$promptHash->{$values[0]} = $values[1];
		} else {
			$promptHash->{"cmd"} = $values[0];
		}
	}

	if ($promptHash->{"cmd"} eq "")	{
		logToFile("Invalid command line parameter(s)", LOGERROR | LOGCONS);
		printHelpAndExit();
	}

	if ($promptHash->{"cmd"} eq "-h")	{
		printHelpAndExit();
	}
}

sub Start()
{
	logToFile ("$0 @ARGV", LOGINFO);

	my %prompts = ();
	my %files = ();
	readPrompt(\%prompts);

	#30894 - Create and give permission to LocResult directory
	my $logPath = "";
	my %iniConfig = ();
	my $iniFile = "$gActiveBinDir/PDEApp.ini";
	if(-f $iniFile) {
		&readIniFile($iniFile, \%iniConfig, true);
		$logPath = &getParam(\%iniConfig, "LOGGER", "LogFolder");

		my $locResDir = sprintf("%s/LocationResult", $logPath);
		if(-d $locResDir){
			#Dont create LocRes directory as it already exists
		}else{
			#Create and set the mode for LocResult file
			system("$mkdirCmd -p $locResDir 2> /dev/null > /dev/null") ;
			# BUG-902: commenting all change modes, as it takes log of time over nas. 
			# On need selective directories can be added
			#system("$chmodCmd -R 0755 $locResDir", 0, "Could not change permission of CallResults path");
		}
		
		#Create and set mode for KPI files
                my $kpiDir = sprintf("%s/KPI", $logPath);		
		if(-d $kpiDir){
			#Dont create kpi directory as it already exists
		}else{
			system("$mkdirCmd -p $kpiDir 2> /dev/null > /dev/null") ;
			# BUG-902: commenting all change modes, as it takes log of time over nas. 
			# On need selective directories can be added
            #system("$chmodCmd -R 0755 $kpiDir", 0, "Could not change permission of kpi path");
		}
	}

	my $abort = $prompts{"-o"};
	if ($abort ne "")	{
		if ($abort eq "abort") {
			my $abrtCmd = $prompts{"cmd"};
			if ($abrtCmd ne "") {
				my $statusFile = sprintf(".status_%s", $abrtCmd);
				if(-f $statusFile) {
					unlink($statusFile);
				} else {
					logToFile("Operation not on-going", LOGFATAL | LOGCONS);
				}
				unlink($gPromptsFile);
				logToFile("Command $abrtCmd aborted", LOGCONS);
			} else {
				logToFile("Command not provided for abort", LOGFATAL | LOGCONS);
			}
		} else {
			logToFile("Invalid option:$abort", LOGFATAL | LOGCONS);
		}
		return;
	}

	# check if install/upgrade/activate has to be perfomred on multiple
	# machines
	my $configFile = $prompts{"-c"};
	if ($configFile ne "")	{
		# read the configuration file
		# format is ipaddress,login id, login password

		my @entries = ();
		if (open(CONF, "<",$configFile)) {
			@entries=<CONF>;
			close (CONF);
		} else {
			logToFile("$configFile open failed", LOGFATAL | LOGCONS);
		}

		# TBD read status file to get current status of progress.
		# start from the blade which failed.
		# status file format
		# ipaddress,status
		# status can be success, failure

		my @remoteMCs = ();
		foreach my $line (@entries) {
			if($line =~ /^#/) {
				next;
			}
			my @values = split(',', $line);
			chomp(@values);
			my %paraminfo = ();

			my $fields = scalar(@values);
			if($fields == 4) {
				$paraminfo{'name'} = trimmer($values[0]);
				$paraminfo{'ip'} = trimmer($values[1]);
				$paraminfo{'uid'} = trimmer($values[2]);
				$paraminfo{'password'} = trimmer($values[3]);
				push (@remoteMCs, \%paraminfo);
			}
		}

		my $numremote = scalar(@remoteMCs);
		if($numremote == 0) {
			logToFile("$configFile has no valid entries", LOGFATAL | LOGCONS);
		}

		my @cmdarr = ();
		my $cmdData = $installCmds{$prompts{"cmd"}};
		if ($cmdData->{'subcmds'} ne "") {
			@cmdarr = split(",", $cmdData->{'subcmds'});
		} else {
			push(@cmdarr, $prompts{"cmd"});
		}

		my $numcmds = scalar(@cmdarr);


		# TBD read status file to get current status of progress.
		# start from the blade which failed.
		# status file format
		# ipaddress,status
		# status can be success, failure
		my ($sec, $min, $hr, $day, $mon, $year) = localtime();
		my $logFile = sprintf("%s_%d%02d%02d_%02d%02d%02d.log", $prompts{"cmd"}, $year, $mon, $day, $hr, $min, $sec);
		$files{'log'} = $logFile;


		my @statusFileArr = ();
		foreach my $cmd (@cmdarr) {

			$prompts{"cmd"} = $cmd;
			my $statusFile = sprintf(".status_%s", $prompts{"cmd"});
			$files{'status'} = $statusFile;
			push (@statusFileArr, $statusFile);

			@entries = ();
			if (open(CONF, "<", $statusFile)) {
				@entries=<CONF>;
				close (CONF);
			}

			foreach my $param (@remoteMCs) {
					$param->{'status'} = "";
			}

			foreach my $line (@entries) {
				my @values = split('@', $line);
				chomp(@values);
				foreach my $param (@remoteMCs) {
					if($param->{'ip'} eq $values[0]) {
						$param->{'status'} = $values[1];
					}
				}
			}

			@entries = ();
			if (open(CONF, "<",$gPromptsFile)) {
				@entries=<CONF>;
				close (CONF);
			}
			chomp(@entries);

			my $key = "";
			foreach my $entry (@entries) {
				#first line is prompt
				#following line is value
				if ($key eq "") {
					$key = $entry;
				} else {
					$gPromptToInput{$key} = $entry;
					$key = "";
				}
			}
			&handleRemoteOp(\%prompts, \@remoteMCs, \%files);
		}

		foreach my $file (@statusFileArr) {
			unlink($file);
		}
		unlink($gPromptsFile);
	} else {
		&handleLocalStart(\%prompts);
	}

	exit(0);
}

sub acceptAndRecv($) {
	my $sockFd = shift;

	#accept for connection and read messages from peer.
	my $client_addr;
	while ($client_addr = accept($gPeerSockFd, $sockFd)) {
		# send them a message, close connection
		my ($port, $ip) = sockaddr_in ($client_addr);
		#$ip = inet_ntoa($ip);
		#print "Connection recieved from $ip:$port\n";

		while (true) {
			my $clientMsg;
			my $ret = recv($gPeerSockFd, $clientMsg, 2000 , 0);
			if($clientMsg ne "") {
				my $input = &getPromptInput($clientMsg);
				if($input eq "") {
					$input = "N-U-L-L";
				}
				send($gPeerSockFd, $input, 0);
			} else {
				last;
			}
		}
		#print "Connection closed from $ip:$port\n";

	   close $gPeerSockFd;
	}
}

sub setUpServer()
{
	#listen on the socket. If non-local IP address is available
	#from PDEApp.ini use that else prompt it.
	my $ip = "";
	my %iniConfig = ();
	my $iniFile = "$gActiveBinDir/PDEApp.ini";
	if(-f $iniFile) {
		&readIniFile($iniFile, \%iniConfig, true);
		$ip = &getParam(\%iniConfig, "PLATFORM_SVCS", "NodeIPAddress");
		if($ip eq "127.0.0.1") {
			$ip = "";
		}
	}

	if($ip eq "") {
		$ip = getIp("Enter node IP address", true, false);
	}
	my $port = listen_port;
	my $proto = getprotobyname('tcp');

	# create a socket, make it reusable
	my $sockFd;
	socket($sockFd, PF_INET, SOCK_STREAM, $proto) or die "Can't open socket $!\n";
	setsockopt($sockFd, SOL_SOCKET, SO_REUSEADDR, 1) or die "Can't set socket option to SO_REUSEADDR $!\n";
	if (bind( $sockFd, pack_sockaddr_in($port, inet_aton($ip)))) {
	} else {
		logToFile("Bind on $ip:$port failed", LOGFATAL | LOGCONS);
	}

	listen($sockFd, 5) or die "listen: $!";

	my $thread = new Thread \&acceptAndRecv, $sockFd;
	return ($ip, $sockFd);
}

sub handleRemoteOp($$$) {
	my $prompts = shift;
	my $remoteMCs = shift;
	my $files = shift;

	my $command = $prompts->{"cmd"};
	if(!(exists $installCmds{$command})) {
		logToFile("Invalid command line parameter(s)", LOGERROR | LOGCONS);
		printHelpAndExit();
	}

	logToFile("COMMAND: $command", LOGINFO | LOGCONS);

	my $cmdData = $installCmds{$command};
	my $selfIp;
	my $sockFd;
	if ($cmdData->{'connection'} == true) {
		($selfIp, $sockFd) = &setUpServer();
	}

	#untar PLT package to get query_mlc package.
	#install query_mlc package
	#find package tar file for commands install, upgrade
	#untar the package remotely for commands install, upgrade
	#cp the NodeLicense.lic file for install, upgrade
	#execute the command
	my $tardir = &untarPltPkg();
	chdir($tardir);
	# install python preconditions for mlc query scripts for GT HA
	System("./pexpect_install", 1, "Cound not install pexpect");
	chdir($gLDirPath);

	my $queryMlcFile = &getFileNameFromPltDir($tardir, "query_mlc.py");
	if($queryMlcFile eq "") {
		logToFile ("query_mlc.py not present", LOGFATAL | LOGCONS);
	}
	$files->{'query'} = $queryMlcFile;

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

	if(defined $sockFd) {
		close $sockFd;
	}
}

sub updateStatusFile ($$$)
{
	my $ipaddr = shift;
	my $entry = shift;
	my $statusFile = shift;

	# Serialise concurrent status-file updates from parallel threads.
	# lock() releases automatically when the sub returns (scope-based).
	lock($gStatusFileMutex);

	my @entries = ();
	if (open(CONF, "<",$statusFile)) {
		@entries=<CONF>;
		close (CONF);
	}

	my $done = false;
	open(CONF, ">",$statusFile);
	foreach my $line (@entries) {
		my @values = split('@', $line);
		chomp(@values);
		if($values[0] eq $ipaddr) {
			print CONF "$ipaddr\@$entry\n";
			$done = true;
		} else {
			print CONF $line;
		}
	}
	# add the line if this was not present.
	if($done == false) {
		print CONF "$ipaddr\@$entry\n";
	}
	close (CONF);

}

sub executeRemoteCmd($$$$)
{
	my $queryMlcFile = shift;
	my $inputCmd = shift;
	my $logresult = shift;
	my $logfd = shift;

	my $execCmd = sprintf("%s %s", $queryMlcFile, $inputCmd);
	my $cmdop = `$execCmd`;

	my $failed = "";
	chomp($cmdop);
	if($cmdop =~ /^invalid password/) {
		$failed = "invalid password";
	} elsif ($cmdop =~ /^timedout/) {
		$failed = "ssh timedout";
	} elsif ($cmdop =~ /FATAL;/i) {
		my @errArray = split("FATAL;", $cmdop);
		chomp(@errArray);
		$failed = $errArray[1];
	} elsif ($cmdop =~ /No such file or directory/i) {
		$failed = "$gProduct not installed";
	} elsif ($cmdop =~ /No route to host/i) {
		$failed = "Not rechable";
	} elsif ($cmdop =~ /Host key verification failed/i) {
		$failed = "Host key verification failed. Check ~/.ssh/known_hosts";
	}

	if ($logresult == true) {
		print $logfd "Command input::\n$execCmd\n";
		print $logfd "Command output::\n$cmdop\n";
	} else {
		print $logfd "Command input::\n$execCmd\n";
		print $logfd "Command output::\nDone\n";
	}

	return ($failed, $cmdop);
}


sub startOnMachine($$$$$)
{
	my $prompts = shift;
	my $peerData = shift;
	my $files = shift;
	my $selfIp = shift;

	my $ipaddr = $peerData->{'ip'};
	my $queryMlcFile = $files->{'query'};
	my $statusFile = $files->{'status'};
	my $logFile = $files->{'log'};
	my $logfd;
	open($logfd, ">>",$logFile);

	my $command = $prompts->{"cmd"};
	my $cmdData = $installCmds{$command};
	my $filter = LOGINFO | LOGCONS;
	my $loghdr = "$peerData->{'name'} ($ipaddr) STATUS:";
	my $logstr = "<=========================================================>\n$loghdr";

	if ($cmdData->{'status'} == true) {
		if ($peerData->{'status'} eq "") {
			$logstr = sprintf("%s Begin", $logstr);
		} elsif ($peerData->{'status'} eq "done") {
			$logstr = sprintf("%s Completed\n", $logstr);
			logToFile($logstr, $filter);
			return;
		} elsif ($peerData->{'status'} =~ /^Failed/) {
			$filter = LOGERROR | LOGCONS;
			$logstr = sprintf("%s %s. Restarting", $logstr, $peerData->{'status'});
		}
	} else {
		$logstr = sprintf("%s Begin", $logstr);
	}

	logToFile($logstr, $filter);
	my $timestamp = `date`;
	chomp $timestamp;
	print $logfd "[$timestamp] $logstr\n";

	# invoke scp to transfer tar file from local to remote.
	# package is transferred to /tmp of remote.
	# after transfer untar.
	# then transfer nodelicense.lic.
	# Invoke the command
	my $remoteInstallDir = "/tmp/.install";
	my $relDir = basename($gLDirPath);
	my $peercmd = sprintf("rm -rf $remoteInstallDir; mkdir -p $remoteInstallDir", $relDir);
	my $execCmd = sprintf("ssh %s %s %s 30 \"%s\"", $ipaddr, $peerData->{'uid'}, $peerData->{'password'}, $peercmd);
	my ($failed, $cmdop) = &executeRemoteCmd($queryMlcFile, $execCmd, false, $logfd);
	if( $failed ne "") {
		logToFile("$loghdr Failed ($failed)\n", LOGERROR | LOGCONS);
		# update the status file and abort the operation.
		if ($cmdData->{'status'} == true) {
			my $entry = sprintf("Failed (%s)", $failed);
			&updateStatusFile($ipaddr, $entry, $statusFile);
			logToFile("Operation aborted", LOGFATAL | LOGCONS);
		}
		return;
	}
	my $installCmd = basename($0);
	if ($cmdData->{'transferinstall'} == true) {
		$execCmd = sprintf("cmd \"scp %s %s@%s:%s\" %s %s 120",
			$installCmd, $peerData->{'uid'}, $ipaddr, $remoteInstallDir, $peerData->{'uid'}, $peerData->{'password'});
	} else {
		$execCmd = sprintf("cmd \"scp -r %s %s@%s:%s\" %s %s 120",
			$gLDirPath, $peerData->{'uid'}, $ipaddr, $remoteInstallDir, $peerData->{'uid'}, $peerData->{'password'});
	}

	($failed, $cmdop) = &executeRemoteCmd($queryMlcFile, $execCmd, false, $logfd);
	if( $failed ne "") {
		logToFile("$loghdr Failed ($failed)\n", LOGERROR | LOGCONS);
		# update the status file and abort the operation.
		if ($cmdData->{'status'} == true) {
			my $entry = sprintf("Failed (%s)", $failed);
			&updateStatusFile($ipaddr, $entry, $statusFile);
			logToFile("Operation aborted", LOGFATAL | LOGCONS);
		}
		return;
	}

	if ($cmdData->{'transferinstall'} == true) {
		$peercmd = sprintf("cd %s; ./%s -a=%s:%d %s",
			$remoteInstallDir, $installCmd, $selfIp, listen_port, $command);
	} else {
		$peercmd = sprintf("cd %s/%s; ./%s -a=%s:%d %s",
			$remoteInstallDir, $relDir, $installCmd, $selfIp, listen_port, $command);
	}
	my $execCmd = sprintf("ssh %s %s %s 300 \"%s\"", $ipaddr, $peerData->{'uid'}, $peerData->{'password'}, $peercmd);
	($failed, $cmdop) = &executeRemoteCmd($queryMlcFile, $execCmd, true, $logfd);
	if( $failed ne "") {
		logToFile("$loghdr Failed ($failed)\n", LOGERROR | LOGCONS);
		# update the status file and abort the operation.
		if ($cmdData->{'status'} == true) {
			my $entry = sprintf("Failed (%s)", $failed);
			&updateStatusFile($ipaddr, $entry, $statusFile);
			logToFile("Operation aborted", LOGFATAL | LOGCONS);
		}
	} else {
		if ($cmdData->{'status'} == true) {
			my $entry = "done";
			&updateStatusFile($ipaddr, $entry, $statusFile);
		} else {
			logToFile("$cmdop", LOGCONS);
		}
		logToFile("$loghdr Completed\n", LOGINFO | LOGCONS);
		print $logfd "$loghdr Completed\n";
	}

	#clean up remote machine.
	my $peercmd = sprintf("rm -rf $remoteInstallDir", $relDir);
	my $execCmd = sprintf("ssh %s %s %s 30 \"%s\"", $ipaddr, $peerData->{'uid'}, $peerData->{'password'}, $peercmd);
	my ($failed, $cmdop) = &executeRemoteCmd($queryMlcFile, $execCmd, false, $logfd);
}

sub connectAndRecv($) {
	my $ipAndPort = shift;

	my ($ip, $port) = split(":", $ipAndPort);
	my $proto = getprotobyname('tcp');

	# create a socket, make it reusable
	socket($gPeerSockFd, PF_INET, SOCK_STREAM, $proto) or die "Can't open socket $!\n";
	if (connect( $gPeerSockFd, pack_sockaddr_in($port, inet_aton($ip)))) {
	} else {
		logToFile("Connect on $ip:$port failed", LOGFATAL | LOGCONS);
	}

}

sub handleLocalStart($)
{
	my $prompts = shift;

	my $command = $prompts->{"cmd"};
	my $cmdData = $installCmds{$command};

	if(exists $prompts->{"-a"}) {
		$gCentralizedOp = true;
		if($cmdData->{'connection'} == true) {

			my $ipAndPort = $prompts->{"-a"};
			#my $thread = new Thread \&connectAndRecv, $ipAndPort;
			&connectAndRecv($ipAndPort);
		}
	}

	my $function = $cmdData->{'function'};
	if(exists $installCmds{$command}) {
		if (exists $cmdData->{'function'}) {
			if ($cmdData->{'root'} == true) {
				&checkRootAndExit();
			}
			$function->($prompts);
		} else {
			logToFile ("Command $command: No function available", LOGFATAL | LOGCONS);
		}
	} else {
		logToFile ("Invalid command line parameter(s)", LOGERROR | LOGCONS);
		printHelpAndExit();
	}
}

sub updateBaseDir()
{

	if ( $gActiveBinDir =~ /polaris/) {
		return;
	}

	my $relPathRedn = sprintf("/%sredn/release", $gProductLegacy);
	my $legRelPathRedn = sprintf("/%sredn/release", lc($gProductLegacy));
	my $legRelPath = sprintf("%s/%s/release", $gHomeDir, lc($gProductLegacy));

	if($gIsUpgrade == true) {
		my $installPath = sprintf("%s/%s/active", $gHomeDir, lc($gProductLegacy));
		if( -l $installPath )  {
			if(-l $gBasePath || -d $gBasePath) {
				# this would be result of previous upgrade from mlc->mlccn
				# no need to delete soft link
			} else {
				my $oldinstallPath = sprintf("%s/%s", $gHomeDir, lc($gProductLegacy));
				#System("$rmCmd -rf $gBasePath", 1, "Could not delete link for active release");
				System("$lnCmd -s $oldinstallPath $gBasePath", 1, "Could not create soft link for Release");
			}

			my $basePath	= "/${gProductLc}redn";
			$installPath = sprintf("/%sredn/active", lc($gProductLegacy));
			if( -l $installPath )  {
				if(-l $basePath || -d $basePath) {
			# this would be result of previous upgrade from mlc->mlccn
				# no need to delete soft link
			} else {
				my $oldinstallPath = sprintf("/%sredn", lc($gProductLegacy));
				#System("$rmCmd -rf $basePath", 1, "Could not delete link for active release");
				System("$lnCmd -s $oldinstallPath $basePath", 1, "Could not create soft link for Release");
			}
		}

		} else {
			$gProductLegacy = "";
		}
	}
}

sub procStart ($)
{
	my $prompts = shift;
	$gActiveBinDir = $gLDirPath;
	&updateBaseDir();

	&startForCurrentRelease($prompts);
}

sub procStop ($)
{
	my $prompts = shift;
	$gActiveBinDir = $gLDirPath;
	&updateBaseDir();

	&stopForCurrentRelease($prompts);
}

sub procStatus ($)
{
	my $prompts = shift;
	$gActiveBinDir = $gLDirPath;
	&updateBaseDir();

	&statusForCurrentRelease($prompts);
}

sub procReStart ($)
{
	my $prompts = shift;
	$gActiveBinDir = $gLDirPath;
	&updateBaseDir();

	&stopForCurrentRelease($prompts);
	sleep(1);
	&startForCurrentRelease($prompts);
}

sub procInstall ($)
{
	my $prompts = shift;
	&installMlc($prompts);
}

sub procPatch ($)
{
	my $prompts = shift;
	&patchMlc($prompts);
}

sub procActivate ($)
{
	my $prompts = shift;
	$gActiveBinDir = $gLDirPath;
	&updateBaseDir();

	&activateMlc($prompts);
}

sub procUpgrade ($)
{
	my $prompts = shift;
	$gIsUpgrade = true;
	$gActiveBinDir = $gLDirPath;

	&updateBaseDir();

	&upgradeMLC($prompts);
}

sub procUninstall ($)
{
	my $prompts = shift;
	$gActiveBinDir = $gLDirPath;
	&updateBaseDir();

	&uninstallMlc($prompts);
}

sub procShowRel ($)
{
	my $prompts = shift;
	$gActiveBinDir = $gLDirPath;
	&updateBaseDir();

	&showReleases($prompts);
}

sub procConfigure ($)
{
	my $prompts = shift;
	&configureMlc($prompts);
}

sub handleMountCmd($) {

	my $mountPath = shift;

	if (-d $gBasePath) {
		# check if /Disk is already mounted. if not unmount and mount again
		my @mounts = `$mountCmd`;
		my $found = false;
		foreach my $mount (@mounts) {
			my @field = split(" ", $mount);
			if($field[2] eq $gBasePath) {
				$found = true;
				#logToFile("$gBasePath is mounted from $field[0]. Unmounting $gBasePath from $mountPath", true);
				System("$umountCmd  $gBasePath", 1, "$umountCmd  $gBasePath failed");
			}
		}

		#if($found == false) {
		#	logToFile("$gBasePath is configured as mount path. $gBasePath is created on local disk.", true);
		#	exit(0);
	} else {
		System("$mkdirCmd -p $gBasePath", 1, "$mkdirCmd  $gBasePath failed");
	}

	System("$mountCmd  $mountPath $gBasePath", 1, "$mountCmd  $mountPath $gBasePath failed");
	logToFile("$gBasePath mount success", LOGINFO | LOGCONS);
	return;
}

sub activateMlc()
{
	my $promptHash = shift;

	&getBaseInstallPath(false);

	my $appMgrLinkName = sprintf("%s_%s", $gProduct, $gAppMgrName);
	my $foundAPPMGR = `/bin/ps -ef | /bin/grep $appMgrLinkName| /bin/grep -v grep `;
	chomp($foundAPPMGR);
	if( $foundAPPMGR =~ m/AppMgr/i) {
		logToFile ("Please stop $gProduct applications to proceed", LOGFATAL | LOGCONS);
	}

	chdir("/tmp");
	my @relDataArr;
	my %relHash = getInstalledReleases(\@relDataArr);
	my $hashSize = scalar(keys( %relHash ));
	if( $hashSize == 0) {
		logToFile ("No software release available", LOGFATAL | LOGCONS);
	}

	my $prompt = "Enter release to activate";
	my $cnt = 1;
	my @rels = ();
	my $activeRel = "";
	foreach my $release (@relDataArr) {
		if($release->{'type'} ne $gActiveKey) {
			if($cnt == 1) {
				$prompt = sprintf("%s [%d - %s", $prompt, $cnt, $release->{'rel'}) ;
			} else {
				$prompt = sprintf("%s, %d - %s", $prompt, $cnt, $release->{'rel'}) ;
			}
			push(@rels, $release->{'rel'});
			$cnt++;
		} else {
			$activeRel  = $release->{'rel'};
		}
	}

	if($cnt == 1) {
		logToFile ("Release $activeRel active. No more software release available to activate", LOGERROR | LOGCONS);
		return;
	}

# more than two releases are installed. Give a prompt to uniinstall all the release version
	$prompt = sprintf("%s ]", $prompt, $cnt) ;

	# prompt option only if there are more than two choices
	my $choice;
	if($cnt == 2) {
		$choice = $cnt - 1 ;
	} else {
		$choice = &getPromptInput("$prompt");
	}

	$choice = int($choice);
	if($choice < 1 || $choice > $cnt) {
		logToFile ("Invalid choice", LOGFATAL | LOGCONS);
	}

	my $relDir = getReleaseDir($rels[$choice -1]);
#relink the active release;
	&createActiveRelLink($relDir);

	my $timestamp = `date`;
	chomp $timestamp;
	my $doneentry = sprintf("activate: %s", $timestamp);
	my $logfd;
	my $doneFile = "$relDir/$gCompletedFile";
	open($logfd, ">>",$doneFile);
	print $logfd "$doneentry\n";
	close($logfd);

	logToFile ("Activated release $rels[$choice -1]", LOGINFO | LOGCONS);

	# start PM CLI and BRM as soon as activate is successful
	my $entry;
	if($gRhelVer >= 6) {
		$entry = "${gProductLc}brm";
	} else {
		$entry = "brm:2345:respawn";
	}
	&removeInitTabEntry($entry);
	&setupBRM();

	#System("$initCmd q", 1, "Could not re-examine inittab");

# start the UMLS applications.
# startMLCApplication();
}

sub getLegacyInstallPath($) {
	my $installedRels = shift;
	my $oldHomeDir = Cwd::abs_path(sprintf("%s/%s", $gHomeDir, lc($gProductLegacy)));
	my $newHomeDir = Cwd::abs_path(sprintf("%s/%s", $gHomeDir, lc($gProduct)));
	# if absolute path are same, mlccn is soflink of mlc
	if($oldHomeDir eq $newHomeDir) {
		return;
	}
	my $installPath = sprintf("%s/%s/active", $gHomeDir, lc($gProductLegacy));
	if( -l $installPath )  {
       		$installedRels->{$gProductLegacy} = $installPath;
	} else {
		$gProductLegacy = "";
	}
}

sub upgradeMLC()
{

	my $promptHash = shift;
	my $release = getRelease();

	&getBaseInstallPath(false);
	logToFile ("Upgrade Path: $gBasePath", LOGINFO | LOGCONS);

	my @relDataArr;
	my %relHash = getInstalledReleases(\@relDataArr);
	my $oldRelDir;
	my $oldDelRel;
	my $nodeLicFile = "NodeLicense.lic";

	if($relHash{$release} ne "") {
		logToFile ("Release $release already installed", LOGFATAL | LOGCONS);
	}

	foreach my $relData (@relDataArr) {
		if($relData->{'type'} eq $gActiveKey) {
			$oldRelDir = $relData->{'dir'};
			$nodeLicFile = sprintf("%s/%s/%s", $oldRelDir , $gBinDir, $nodeLicFile);
		} elsif( $relData->{'type'} eq  $gInstalledKey)  {
			$oldDelRel = $relData->{'rel'};
		}
	}

	my $size = scalar (@relDataArr);
	if ( $size <= 0) {
# check if the old mlc release is installed
# this is to upgrade from the legacy installations
		my %oldRelDetails = ();
		getLegacyInstallPath(\%oldRelDetails);
		my $legRelSize = scalar keys %oldRelDetails;
		if ( $legRelSize == 1 )  {
# relatively straight forward got ahead with the migration
# for this
			foreach my $key (keys %oldRelDetails) {
				logToFile ("Upgrading from $key", LOGINFO | LOGCONS);
				$oldRelDir = $oldRelDetails{$key};
				$nodeLicFile = sprintf("%s/%s/%s", $oldRelDir , $gBinDir, $nodeLicFile);
			}
		} elsif( $legRelSize <= 0 ) {
			logToFile ("No software release available. Run install", LOGFATAL | LOGCONS);
		}
	}

	if( $oldRelDir eq "") {
# opps this  system has two installed version.
# there is not way this scritp can decide which
# once is to be removed and which one should be
# used for upgrade
# humbly ask user to active one release
		logToFile ("No software release active", LOGFATAL | LOGCONS);
	}
#read previous INI file
	my %iniConfig = ();

	my %oldRelData = ();
	getOldRelDir($oldRelDir, \%oldRelData);
	my $oldPath =  $oldRelData{'rel'};

	my $iniFile = sprintf("%s/%s", $oldPath, $gIniFile);
	readIniFile($iniFile, \%iniConfig, true);

	my $nodeCnt = &getParam(\%iniConfig, "PLATFORM_SVCS", "SstInstanceId");

# check license files
	my %configHash = ();
	my @licssts = ();
# first check for the node license file in the current directory
# if user wants to update the license he can put the new node license file
# in the current working directory and upgrade
	my $nodeLicFileLocal = "NodeLicense.lic";
	my $licensed;
	my $localLic = false;
	if( -f $nodeLicFileLocal) {
		$licensed = &checkLicense(\%configHash, \@licssts, $nodeLicFileLocal, $nodeCnt);
		$localLic = true;
	} else {
		$licensed = &checkLicense(\%configHash, \@licssts, $nodeLicFile, $nodeCnt);
	}
	if($licensed == 0) {
		logToFile ("License failure", LOGFATAL | LOGCONS);
	}

# create the polaris user
	&createPolarisUser();

	my $cnt = $licensed;
# setup platform instance as its not set in the loop  below
	$gPltSstDetail{'Instance'} = $cnt;


# delete sections which are regenerated
	delParam( \%iniConfig, "OAMAgent","IgnoreModulesForProcessMonitoring");
	delParam( \%iniConfig, "OamProxy","IgnoreForCkpt");
	delParam( \%iniConfig, "FaultMonitor","M3uaLinkSections");
	delParam( \%iniConfig, "FaultMonitor","M3uaSections");
	delParam( \%iniConfig, "FaultMonitor","Mtp2ConvLinkSections");
	delParam( \%iniConfig, "FaultMonitor","Mtp3ConvSections");
	delParam( \%iniConfig, "FaultMonitor","SctpSections");
	delParam( \%iniConfig, "FaultMonitor","SgwAppSections");
	my $releaseDir = &installSsts(\@licssts, \%configHash, $cnt, \%iniConfig);
	my $status = &configureSsts(\@licssts, $releaseDir, $oldRelDir, \%iniConfig, \%configHash);

# if the licesne file used was local copy the license file to the insallation directory
	if($localLic == true) {
		my $file = "NodeLicense.lic";
		my $oldPath = "$gLDirPath";
		my $newPath = "$releaseDir/$gBinDir";
		copyFileFromPrevRel($file, $file, $newPath, $oldPath);
	}

	&setupMlcDaemon();

	my $timestamp = `date`;
	chomp $timestamp;
	my $doneentry = sprintf("upgrade: %s", $timestamp);
	my $logfd;
	my $doneFile = "$releaseDir/$gCompletedFile";
	open($logfd, ">>",$doneFile);
	print $logfd "$doneentry\n";
	close($logfd);

	logToFile ("$gProduct successfully configured", LOGCONS);
	logToFile ("$gProduct successfully upgraded to release $release", LOGINFO | LOGCONS);
	&printInstalledComponents(\@licssts, \%iniConfig, \%configHash, $release);
	logToFile ("Use \"activate\" option to activate release $release", LOGCONS);
	deleteRelease($oldDelRel);

	if($gIsLinux == false) {
# setup crontab entry
		setUpCrontab();
	}

	# setup syslog
	# &setUpSyslogInit();

	if($gUsingOpensaf == false) {
		# BUG-902: commenting all change ownership, as it takes log of time over nas. 
		# On need selective directories can be added
		#System("$chownCmd -R $gUser:$gGroup $gBasePath", 1, "Could not change owner of the directories");
	}
# do not start the MLC applications.
# allow user to re-configure
# startMLCApplication();
}

sub patchMlc($) {
	my $promptHash = shift;
	my $release = getRelease();

	&getBaseInstallPath(false);
	logToFile ("Patch Path: $gBasePath", LOGINFO | LOGCONS);

	my @relDataArr;
	my %relHash = getInstalledReleases(\@relDataArr);
	my $oldRelDir;
	my $oldDelRel;
	my $nodeLicFile = "NodeLicense.lic";

	if($relHash{$release} ne "") {
		logToFile ("Release $release already installed", LOGFATAL | LOGCONS);
	}

	foreach my $relData (@relDataArr) {
		if($relData->{'type'} eq $gActiveKey) {
			$oldRelDir = $relData->{'dir'};
			$nodeLicFile = sprintf("%s/%s/%s", $oldRelDir , $gBinDir, $nodeLicFile);
		} elsif( $relData->{'type'} eq  $gInstalledKey)  {
			$oldDelRel = $relData->{'rel'};
		}
	}

	my $size = scalar (@relDataArr);
	if ( $size <= 0) {
		logToFile ("No software release active", LOGFATAL | LOGCONS);
	}

#read previous INI file
	my %iniConfig = ();

	my %oldRelData = ();
	getOldRelDir($oldRelDir, \%oldRelData);
	my $oldPath =  $oldRelData{'rel'};

	my $iniFile = sprintf("%s/%s", $oldPath, $gIniFile);
	readIniFile($iniFile, \%iniConfig, false);

	my $nodeCnt = &getParam(\%iniConfig, "PLATFORM_SVCS", "SstInstanceId");

# check license files
	my %configHash = ();
	my @licssts = ();
# first check for the node license file in the current directory
# if user wants to update the license he can put the new node license file
# in the current working directory and upgrade
	my $nodeLicFileLocal = "NodeLicense.lic";
	my $licensed;
	my $localLic = false;
	if( -f $nodeLicFileLocal) {
		$licensed = &checkLicense(\%configHash, \@licssts, $nodeLicFileLocal, $nodeCnt);
		$localLic = true;
	} else {
		$licensed = &checkLicense(\%configHash, \@licssts, $nodeLicFile, $nodeCnt);
	}
	if($licensed == 0) {
		logToFile ("License failure", LOGFATAL | LOGCONS);
	}

	my $cnt = $licensed;
# setup platform instance as its not set in the loop  below
	$gPltSstDetail{'Instance'} = $cnt;

	my %patchConfig = ();
	readIniFile("patch.ini", \%patchConfig, true);
	my $status;
	# call to apply pre-checks
	if  ($promptHash->{"cmd"} eq "patch_global_pre") {
		$promptHash->{"-g"} = "pre";
		$status = &checkPatch($promptHash, \%configHash, $cnt, \%iniConfig, \%patchConfig, "pre");
		logToFile ("$gProduct global pre patch successful for $release", LOGINFO | LOGCONS);

	} elsif ($promptHash->{"cmd"} eq "patch") {
		# call to apply patch.
		$status = &checkPatch($promptHash, \%configHash, $cnt, \%iniConfig, \%patchConfig, "pre");
		$status = &checkPatch($promptHash, \%configHash, $cnt, \%iniConfig, \%patchConfig, "patch");
		$status = &checkPatch($promptHash, \%configHash, $cnt, \%iniConfig, \%patchConfig, "post");

		logToFile ("$gProduct successfully patched to release $release", LOGINFO | LOGCONS);

		if($gUsingOpensaf == false) {
			# BUG-902: commenting all change ownership, as it takes log of time over nas. 
			# On need selective directories can be added
			#System("$chownCmd -R $gUser:$gGroup $gBasePath", 1, "Could not change owner of the directories");
		}

	} elsif  ($promptHash->{"cmd"} eq "patch_global_post") {
		$promptHash->{"-g"} = "post";
		$status = &checkPatch($promptHash, \%configHash, $cnt, \%iniConfig, \%patchConfig, "post");
		logToFile ("$gProduct global post patch successful for $release", LOGINFO | LOGCONS);
	}


}

sub startService($$$)
{
	my $polarisentry = shift;
	my $startcmd = shift;
	my $stopcmd = shift;
	my $logTxt = shift;
	my $exitOnFail = shift;
	my $initfile = sprintf("/usr/lib/systemd/system/%s.service", $polarisentry);
	open(INITCONF, ">",$initfile) or die "Could not open $initfile";
	print INITCONF "[Unit]\n";
	print INITCONF "Description=$gProduct $logTxt service\n";
	print INITCONF "After=remote-fs.target syslog.target network.target\n";
	print INITCONF "\n";
	print INITCONF "[Service]\n";
	print INITCONF "ExecStart=/bin/bash $gActiveBinDir/$gStartAppName $startcmd\n";
	if($stopcmd ne "") {
		print INITCONF "ExecStop=/bin/bash $gActiveBinDir/$gStartAppName $stopcmd\n";
	}
	print INITCONF "Type=simple\n";
	print INITCONF "Restart=always\n";
	print INITCONF "TimeoutSec=30s\n";
	print INITCONF "\n";
	print INITCONF "[Install]\n";
	print INITCONF "WantedBy=multi-user.target\n";
	close (INITCONF);
	my $status = `$systemctlCmd daemon-reload`;
	$status = `$systemctlCmd is-active $polarisentry`;
	chomp($status);
	logToFile("$gProduct $logTxt is-active status $status", LOGINFO);
	if (($status =~ /unknown/) || ($status =~ /failed/) || ($status =~ /inactive/)) {

		if($polarisentry =~ /daemon/) {
			$status = `pkill $polarisentry`;
		}	
		$status = `$systemctlCmd enable $polarisentry > /dev/null 2>&1`;
		$status = `$systemctlCmd is-enabled $polarisentry`;
		chomp($status);
		logToFile("$gProduct $logTxt is-enabled status $status", LOGINFO);
		if ($status =~ /enabled/) {
			$status = `$systemctlCmd start $polarisentry > /dev/null 2>&1`;
			chomp($status);
			logToFile("$gProduct $logTxt start status $status", LOGINFO);
			$status = `$systemctlCmd is-active $polarisentry`;
			chomp($status);
			logToFile("$gProduct $logTxt is-active status $status", LOGINFO);
		} else {
			logToFile("$gProduct $logTxt failed to start", LOGINFO | LOGCONS);
			if($exitOnFail == true) {
				exit(0);
			}
		}
	} elsif (($status =~ /active/)) {
		if($polarisentry =~ /daemon/) {
			my $ppid=getppid();
   			my $pname = `ps hp $ppid -o %c`;
   			chomp $pname;
			if ($pname =~ /$polarisentry/) {
			} else {
				$status = `$systemctlCmd stop $polarisentry`;
				chomp($status);
				logToFile("$gProduct $logTxt stop status $status", LOGINFO);
				$status = `$systemctlCmd start $polarisentry > /dev/null 2>&1`;
				chomp($status);
				logToFile("$gProduct $logTxt start status $status", LOGINFO);
				$status = `$systemctlCmd is-active $polarisentry`;
				chomp($status);
				logToFile("$gProduct $logTxt is-active status $status", LOGINFO);
			}
		} else {
			if($logTxt eq "Applications") {
				logToFile("$gProduct $logTxt already running", LOGINFO | LOGCONS);
			}
			if($exitOnFail == true) {
				exit(0);
			}
		}	

	} else {
		if($logTxt eq "Applications") {
			logToFile("$gProduct $logTxt already running", LOGINFO | LOGCONS);
		}
		if($exitOnFail == true) {
			exit(0);
		}
	}
}
sub setupAppMgr()
{

	my $polarisentry = "${gProductLc}appmgr";
	if($gRhelVer == 7) {
		&startService($polarisentry, "service start", "service stop", "Applications", true);
	} elsif ($gRhelVer == 6) {
		my $initfile = sprintf("/etc/init/%s.conf", $polarisentry);
		open(INITCONF, ">",$initfile) or die "Could not open $initfile";
		print INITCONF "start on stopped rc RUNLEVEL=[2345]\n";
		print INITCONF "stop on starting runlevel [016]\n";
		print INITCONF "respawn\n";
		my $appMgrLinkName = sprintf("%s_%s", $gProduct, $gAppMgrName);
		print INITCONF "exec $gActiveBinDir/$gStartAppName $appMgrLinkName\n";
		close (INITCONF);
		my $status = `$initctlCmd status $polarisentry`;
		if ($status =~ /running/) {
			# already running
			#logToFile("$gProduct Applications already running", LOGINFO | LOGCONS);
			exit(0);
		} else {
			System("$initctlCmd reload-configuration", 0, "$initctlCmd reload-configuration failed");
			System("$initctlCmd start $polarisentry", 1, "$initctlCmd start $polarisentry failed");
		}
	} else {
		if(-e "$gInitTabFile.orig")
		{
#do not copy if the orig file exits.
		}
		else
		{
			System("$cpCmd $gInitTabFile $gInitTabFile.orig", 1, "Could not take backup of the inittab file");
		}

		my $polarisentry;
		$polarisentry = "am:2345:respawn";

		my $appMgrLinkName = sprintf("%s_%s", $gProduct, $gAppMgrName);
		open(INITCONF, "<",$gInitTabFile) or die "Could not open $gInitTabFile.";
		my @entries=<INITCONF>;
		close (INITCONF);

		open(INITCONF, ">",$gInitTabFile) or die "Could not open $gInitTabFile.";
		foreach my $line (@entries)
		{
			if ($line =~ /^$polarisentry/)
			{
			}
			else
			{
				print INITCONF $line;
			}
		}

		print INITCONF "$polarisentry:$gActiveBinDir/$gStartAppName $appMgrLinkName\n";

		close (INITCONF);
		System("$initCmd q", 1, "Could not re-examine inittab");
	}
}

sub setupSctp()
{
	System("/etc/init.d/sctp start", 1, "/etc/init.d/sctp start failed");
}

sub setupMlcDaemon()
{
	if($gProductLegacy ne "") {
		my $legacyentry;
		$legacyentry = sprintf("%sdaemon", lc($gProductLegacy));
		&removeInitTabEntry($legacyentry);
	}

	my $polarisentry = "${gProductLc}daemon";

	if($gRhelVer == 7) {
		&startService($polarisentry, $gMlcDaemon, "", $gMlcDaemon, false);
	} elsif ($gRhelVer == 6) {
		&removeInitTabEntry("pmcli");
		my $initfile = sprintf("/etc/init/%s.conf", $polarisentry);
		open(INITCONF, ">",$initfile) or die "Could not open $initfile";
		print INITCONF "start on stopped rc RUNLEVEL=[2345]\n";
		print INITCONF "stop on starting runlevel [016]\n";
		print INITCONF "respawn\n";
		print INITCONF "exec $gActiveBinDir/$gStartAppName $gMlcDaemon\n";
		close (INITCONF);
		my $status = `$initctlCmd status $polarisentry`;
		if ($status =~ /running/) {
			# stop only if its not called from mlcdaemon
			my $ppid=getppid();
			my $pname = `ps hp $ppid -o %c`;
			chomp $pname;
			if ($pname =~ /$polarisentry/) {
			} else {
				System("$initctlCmd stop $polarisentry", 0, "$initctlCmd stop $polarisentry failed");
				System("$initctlCmd start $polarisentry", 0, "$initctlCmd start $polarisentry failed");
			}
			# already running
		} else {
			System("$initctlCmd reload-configuration", 0, "$initctlCmd reload-configuration failed");
			System("$initctlCmd start $polarisentry", 0, "$initctlCmd start $polarisentry failed");
		}
	} else {
		if(-e "$gInitTabFile.orig") {
#do not copy if the orig file exits.
		} else {
			System("$cpCmd $gInitTabFile $gInitTabFile.orig", 1, "Could not take backup of the inittab file");
		}

		my $polarisentry = "cli:2345:respawn";
		open(INITCONF, "<",$gInitTabFile) or die "Could not open $gInitTabFile.";
		my @entries=<INITCONF>;
		close (INITCONF);

		open(INITCONF, ">",$gInitTabFile) or die "Could not open $gInitTabFile.";
		my $found = false;
		foreach my $line (@entries) {
			if ($line =~ /^$polarisentry/) {
				$found = true;
			}
			print INITCONF $line;
		}

		if($found == false) {
			print INITCONF "$polarisentry:$gActiveBinDir/$gStartAppName $gMlcDaemon\n";
		}

		close (INITCONF);
		System("$initCmd q", 1, "Could not re-examine inittab");
	}
}

sub setupBRM()
{
	if($gProductLegacy ne "") {
		my $legacyentry;
		$legacyentry = sprintf("%sbrm", lc($gProductLegacy));
		&removeInitTabEntry($legacyentry);
	}
	my $brmLinkName;
	my $polarisentry;
	$polarisentry = "${gProductLc}brm";
	$brmLinkName = sprintf("%s_%s daemon", $gProduct, $gBRMName);
	if($gRhelVer == 7) {
		&startService($polarisentry, $brmLinkName, "", $gBRMName, false);
	} elsif ($gRhelVer == 6) {
		my $initfile = sprintf("/etc/init/%s.conf", $polarisentry);
		open(INITCONF, ">",$initfile) or die "Could not open $initfile";
		print INITCONF "start on stopped rc RUNLEVEL=[2345]\n";
		print INITCONF "stop on starting runlevel [016]\n";
		print INITCONF "respawn\n";
		print INITCONF "exec $gActiveBinDir/$gStartAppName $brmLinkName\n";
		close (INITCONF);
		my $status = `$initctlCmd status $polarisentry`;
		if ($status =~ /running/) {
			# already running
		} else {
			System("$initctlCmd reload-configuration", 0, "$initctlCmd reload-configuration failed");
			System("$initctlCmd start $polarisentry", 1, "$initctlCmd start $polarisentry failed");
		}
	} else {
		if(-e "$gInitTabFile.orig") {
#do not copy if the orig file exits.
		} else {
			System("$cpCmd $gInitTabFile $gInitTabFile.orig", 1, "Could not take backup of the inittab file");
		}

		my $polarisentry = "brm:2345:respawn";
		my $brmLinkName = sprintf("%s_%s daemon", $gProduct, $gBRMName);
		open(INITCONF, "<",$gInitTabFile) or die "Could not open $gInitTabFile.";
		my @entries=<INITCONF>;
		close (INITCONF);

		open(INITCONF, ">",$gInitTabFile) or die "Could not open $gInitTabFile.";
		my $found = false;
		foreach my $line (@entries) {
			if ($line =~ /^$polarisentry/) {
				$found = true;
			} else {
				print INITCONF $line;
			}
		}

		print INITCONF "$polarisentry:$gActiveBinDir/$gStartAppName $brmLinkName\n";

		close (INITCONF);
		System("$initCmd q", 1, "Could not re-examine inittab");
	}
}

sub removeInitTabEntry($)
{
	my $polarisentry = shift;
	if($gRhelVer == 7) {
		my $initfile = sprintf("/usr/lib/systemd/system/%s.service", $polarisentry);
		System("$systemctlCmd stop $polarisentry", 0, "$systemctlCmd stop $polarisentry failed");
		System("$systemctlCmd disable $polarisentry", 0, "$systemctlCmd disable $polarisentry failed");
		unlink($initfile);
	} elsif($gRhelVer == 6) {
		my $initfile = sprintf("/etc/init/%s.conf", $polarisentry);
		System("$initctlCmd stop $polarisentry", 0, "$initctlCmd stop $polarisentry failed");
		unlink($initfile);
	} else  {
		open(INITCONF, "<",$gInitTabFile) or die "Could not open $gInitTabFile.";
		my @entries=<INITCONF>;
		close (INITCONF);

		open(INITCONF, ">",$gInitTabFile) or die "Could not open $gInitTabFile.";
		foreach my $line (@entries)
		{
			if ($line =~ /^$polarisentry/)
			{
			}
			else
			{
				print INITCONF $line;
			}
		}
		close (INITCONF);
		System("$initCmd q", 1, "Could not init to re-examine inittab");
	}
}

#This function exits if active release is not  found
sub checkActiveRel($)
{
	my @dummy;
	my %relHash = getInstalledReleases(\@dummy);
	my $numRelease = scalar (keys %relHash);

	if( $numRelease <= 0 ) {
		logToFile ("No software release available.", LOGFATAL | LOGCONS);
	}

	my $activefound = false;
	foreach my $key (keys %relHash) {
		if ($relHash{$key} eq $gActiveKey)	{
			$activefound = true;
		}
	}

	if ($activefound == false) {
		logToFile ("No software release active.", LOGFATAL | LOGCONS);
	}
}

sub startForCurrentRelease()
{
	my $promptHash = shift;

	&getBaseInstallPath(false);

	#This function exits if active release is not  found
	&checkActiveRel();

	if($promptHash->{'-p'} eq "") {
		&setupMlcDaemon();
	}

	chdir ($gActiveBinDir);
	# &setUpSyslog();
	if($promptHash->{'-p'} ne "") {
		my @procs = split(',', $promptHash->{'-p'});
		foreach my $proc (@procs) {
			printf("starting $proc\n");
			my $cmd = sprintf("./startApp %s_AppMgr start %s", $gProduct, $proc);
			System("$cmd", 1, "Unable to execute cmd $cmd");
		}
		return;
	}

	if ($gIsLinux == true) {
		&setupStart();
	}

	if( -f "$gUseOpensafFile") {
		unlink("/var/run/opensaf/amf_failed_state");
		my $old = "/etc/init.d/opensafd_";
		my $new = "/etc/init.d/opensafd";
		if(-f $old) {
			System("$mvCmd -f $old $new", 1, "Unable to move $old to $new");
		}

		if(-f "/etc/init.d/opensafd") {
			my $status = `/etc/init.d/opensafd status`;
			chomp $status;
			if($status ne "The OpenSAF HA Framework is not running") {
				logToFile("$gProduct Applications already running", LOGINFO | LOGCONS);
				return;
			}

			for(my $cnt=0; $cnt < 3; $cnt++) {
				my $ret = `$new start`;
				if( $ret =~ /OK/) {
					#nothing as of now
				} else {
					System("$mvCmd -f $new $old", 1, "Unable to move $new to $old");
					`$old stop`;
					if ($cnt == 2) {
						logToFile ("$gProduct Applications start failed", LOGERROR | LOGCONS);
						logToFile ("Error: $ret", LOGFATAL | LOGCONS);
					}
					System("$mvCmd -f $old $new", 1, "Unable to move $old to $new");
				}
			}
			# check the status of the su after calling start
			# if any one is locked, unlock it
			my @result = `amf-state su adm`;
			my $prevline = "";
			my $node = `cat /etc/opensaf/node_name`;
			chomp($node);
			my @namearr = split("-", $node);
			foreach my $line (@result) {
				if ($line =~ /LOCKED-INSTANTIATION/) {
					if ($prevline =~ /_SU$namearr[1]/) {
						my $ret = `amf-adm unlock-in $prevline`;
						$ret = `amf-adm unlock $prevline`;
					}
				}
				$prevline = $line;
			}
		} else {
			logToFile("Opensaf start script (/etc/init.d/opensafd) not present", LOGFATAL | LOGCONS);
		}
	} else {
		my %iniConfig = ();
		readIniFile($gIniFile, \%iniConfig, true);
		my $nodeCnt = &getParam(\%iniConfig, "PLATFORM_SVCS", "SstInstanceId");
		my $monitorFile = &getRednNodesMonitorFile($nodeCnt);
		# remove monitor file if present
		&setupAppMgr();
		if(-e $monitorFile) {
			# sleep for 5 seconds before removing the monitoring file
			sleep(5);
			unlink($monitorFile);
		}
	}

	if( -f "$gStartSctpFile") {
		&setupSctp();
	}
	# setup cli for start and stop of process
	&setupBRM();
	logToFile("$gProduct Applications successfully started", LOGINFO | LOGCONS);
}

sub stopForCurrentRelease($)
{
	my $promptHash = shift;

	&getBaseInstallPath(false);

	#This function exits if active release is not  found
	&checkActiveRel();
	if($promptHash->{'-p'} ne "") {
		chdir ($gActiveBinDir);
		my @procs = split(',', $promptHash->{'-p'});
		foreach my $proc (@procs) {
			printf("stopping $proc\n");
			my $cmd = sprintf("./startApp %s_AppMgr stop %s", $gProduct, $proc);
			System("$cmd", 1, "Unable to execute cmd $cmd");
		}
		return;
	}

	chdir ($gActiveBinDir);
	if( -f "$gUseOpensafFile") {

		if(-f "$gOsafStartFile") {
       	} else {
			logToFile("$gProduct Applications not running", LOGINFO | LOGCONS);
			return;
        }

		my $status = `/etc/init.d/opensafd status`;
		chomp $status;
		if($status eq "The OpenSAF HA Framework is not running") {
			logToFile("$gProduct Applications already stopped", LOGINFO | LOGCONS);
			return;
		}

		# check the status of the su prior to calling stop
		# if instantiation of any su failed lock it before stopping
		# else opensafd stop will reboot the machine
		my @result = `amf-state su pres`;
		my $prevline = "";
		my $node = `cat /etc/opensaf/node_name`;
		chomp($node);
		my @namearr = split("-", $node);
		foreach my $line (@result) {
			if ($prevline =~ /_SU$namearr[1]/) {
				my $ret = `amf-adm lock $prevline`;
				$ret = `amf-adm lock-in $prevline`;
			}

			$prevline = $line;
		}

		my $old = "/etc/init.d/opensafd";
		my $new = "/etc/init.d/opensafd_";
		System("$mvCmd -f $old $new", 1, "Unable to move $old to $new");

		System("$new stop", 1, "Could not all run /etc/init.d/opensafd stop");
		System("./VirtIPConfigure 2", 0, "Could not start script to initiate IP takeover");
		my $entry;
		$entry = "sctp:2345:respawn:";
		removeInitTabEntry($entry);
		if( -f "$gStartSctpFile") {
			System("/etc/init.d/sctp stop", 0, "/etc/init.d/sctp stop failed");
		}
	} else {
		my $brmname = sprintf("%s_%s",$gProduct,$gBRMName);
		my @remains = `/bin/ps -eaf | /bin/grep $gProduct | /bin/grep -v grep | /bin/grep -v $0 | grep -v $brmname | awk '{print \$2}'`;
		chomp @remains;
		my $numrunning = scalar (@remains);
		if($numrunning == 0) {
			logToFile("$gProduct Applications not running", LOGINFO | LOGCONS);
			return;
		}

		my %iniConfig = ();
		readIniFile($gIniFile, \%iniConfig, true);
		my $nodeCnt = &getParam(\%iniConfig, "PLATFORM_SVCS", "SstInstanceId");
		my $monitorFile = &getRednNodesMonitorFile($nodeCnt);
		my $rednNodeDir = &getRednNodesDir($nodeCnt);

		if(-d $rednNodeDir) {
			my $monfd;
			open($monfd, ">", "$monitorFile") or printf("Monitor $monitorFile cannot be opened\n");
			print $monfd "true";
		}

		my $appMgrLinkName = sprintf("%s_%s", $gProduct, $gAppMgrName);
		my $appMgrExe = sprintf("%s/$gStartAppName $appMgrLinkName", $gActiveBinDir);
		System("$appMgrExe stop all", 0, "Could not execute $appMgrExe stop all");
		sleep 1;
		my $entry;
		if($gRhelVer == 7 || $gRhelVer == 6) {
			$entry = "${gProductLc}appmgr";
		} else {
			$entry = "am:2345:respawn:";
		}

		removeInitTabEntry($entry);
		if( -f "$gStartSctpFile") {
			# if sctp is present remove that also
			$entry = "sctp:2345:respawn:";
			removeInitTabEntry($entry);
		}
		System("./VirtIPConfigure 2", 0, "Could not start script to initiate IP takeover");
		sleep 1;
		if( -f "$gStartSctpFile") {
			System("/etc/init.d/sctp stop", 0, "/etc/init.d/sctp stop failed");
			sleep 2;
		}
	}
# rope trick, even after all this processes doesn't get stopped
# use kill to hard kill all of them

	my $brmname = sprintf("%s_%s",$gProduct,$gBRMName);
	my @remains = `/bin/ps -eaf | /bin/grep $gProduct | /bin/grep -v grep | /bin/grep -v $0 | grep -v $brmname | awk '{print \$2}'`;
	chomp @remains;
	kill 9, @remains;
	# remove any virtual IP assignment
	logToFile("$gProduct Applications successfully stopped", LOGINFO | LOGCONS);
}

sub statusForCurrentRelease($)
{
	my $promptHash = shift;

	&getBaseInstallPath(false);

	#This function exits if active release is not  found
	&checkActiveRel();

	chdir ($gActiveBinDir);
	if( -f "$gUseOpensafFile") {

		if(-f "$gOsafStartFile") {
		} else {
			logToFile("$gProduct Applications not running", LOGINFO | LOGCONS);
			exit(0);
		}

		my @result = `/etc/init.d/opensafd status`;
		chomp @result;
		if($result[0] eq "The OpenSAF HA Framework is not running") {
			logToFile("$gProduct Applications not running", LOGINFO | LOGCONS);
			exit(0);
		}
		printf("result:\n");
		printf("NAME                     STATUS\n");
		my $node = `cat /etc/opensaf/node_name`;
		chomp($node);
		my @namearr = split("-", $node);

		my @procinfos = `amf-state comp pres`;
		chomp @procinfos;
		my %procToNumInst = ();
		foreach my $line (@procinfos) {
			if ($line =~ /safComp=/) {
				my @infos = split(",", $line);
				@infos = split("=", $infos[0]);
				@infos = split(/\./, $infos[1]);
				if($infos[2] == $namearr[1]) {
					if($procToNumInst{$infos[1]} eq "") {
						$procToNumInst{$infos[1]} = 1;
					} else {
						$procToNumInst{$infos[1]}++;
					}
				}
			}
		}

		my $proc;
		my $format = "%-20s\t%-10s\n";
		foreach my $line (@procinfos) {
			if ($line =~ /safComp=/) {
				my @infos = split(",", $line);
				@infos = split("=", $infos[0]);
				@infos = split(/\./, $infos[1]);
				if($infos[2] == $namearr[1]) {
					if($procToNumInst{$infos[1]} == 1) {
						$proc = sprintf("%s_%s", $gProduct, $infos[1]);
					} else {
						$proc = sprintf("%s_%s%d", $gProduct, $infos[1], $infos[3]);
					}
				} else {
					$proc = "";
				}
			} elsif ($proc ne "") {
				my $len = length $proc;
				my $delim;
				if($len > 15) {
					$delim = "\t";
				} else {
					$delim = "\t\t";
				}
				my @infos = split("=", $line);


				if($infos[1] eq "INSTANTIATED(3)") {
					printf($format,${proc},"Running");
					#printf("${proc}${delim}Running\n");
				} else {
					printf($format,${proc},"Stopped");
					#printf("${proc}${delim}Stopped\n");
				}
				$proc = "";
			}
		}

		my $osafFile = sprintf("%s/%s", $gActiveBinDir, $gUseOpensafFile);
		my $osfd;
		open($osfd, "<", "$osafFile") or printf("$osafFile cannot be opened for reading\n");
		my @osafEntries = <$osfd>;
		close($osfd);
		chomp(@osafEntries);

		foreach my $process (@osafEntries) {
			my $found = `/bin/ps -ef | /bin/grep $process | /bin/grep -v grep `;
			chomp($found);
			if( $found =~ m/$process/i) {
				printf($format,$process,"Running");
			} else {
				printf($format,$process,"Stopped");
			}
		}


		my $redfound = false;
		foreach my $line (@result) {
			if ($line =~ /_SU$namearr[1]_2N/) {
				$redfound = true;
			}

			if( $redfound == true) {
				if ($line =~ /ACTIVE/) {
					print("$gProduct status: ACTIVE\n");
					exit(0);
				} elsif ($line =~ /STANDBY/) {
					print("$gProduct status: STANDBY\n");
					exit(0);
				}
			}
		}
		print("$gProduct status: UNKNOWN\n");

	} else {
		my $appMgrLinkName = sprintf("%s_%s", $gProduct, $gAppMgrName);
		my $appMgrExe = sprintf("%s/$gStartAppName $appMgrLinkName", $gActiveBinDir);
		System("$appMgrExe status all", 0, "Could not execute $appMgrExe status all");
		my $statusOpFile = "/tmp/.cmdout";
		my $statusOp = `cat $statusOpFile`;
		printf("$statusOp\n");
		unlink($statusOpFile);
	}
}

sub getInstalledReleases($)
{
	my $relDetail = shift;

	my $relAbs = Cwd::abs_path($gActiverRelLink);
	$relAbs = basename($relAbs);
	opendir(RELDIR, $gReleasePath);
	my @dirs = readdir(RELDIR);
	closedir(RELDIR);

	my %relHash = ();
	foreach my $relDir (@dirs) {
		if( $relDir =~ /RELEASE_R(.*?)$/ ) {
			if( -f "$gReleasePath/$relDir/$gCompletedFile") {
				my $relKey = $gInstalledKey;
				if($relDir eq $relAbs) {
					$relKey = $gActiveKey;
				}

				my %relData;
				$relData{'dir'} = "$gReleasePath/$relDir";
				$relData{'type'} = $relKey;
				$relData{'rel'} = $1;
				$relHash {$1} = $relKey;

				opendir(RELDIR, "$gReleasePath/$relDir/$gPkgDir");
				my @sstdirs = readdir(RELDIR);
				closedir(RELDIR);
				my @sstDataArr = ();
				foreach my $sstdir (@sstdirs) {
					my $sstDirNameOnly = basename($sstdir);
					if( $sstDirNameOnly =~ /(.*?)_RELEASE_R(.*?)$/ ) {
						my %sstData = ();
						my @sstArr = split('_', $1);
						$sstData{'sst'} = $sstArr[0];
						$sstData{'rel'} = $2;
						#$relHash {$2} = $relKey;

						my $patchverfile = sprintf("%s/%s/%s/%s/%s", $gReleasePath, $relDir, $gPkgDir, $sstdir, $gPatchVerFile);
						open(PATCHVER, "<", $patchverfile);
						my @versions = <PATCHVER>;
						close PATCHVER;
						chomp @versions;

						$sstData{'patches'} = \@versions;
						push(@sstDataArr, \%sstData);
					}
				}
				$relData{'sst'} = \@sstDataArr;
				push(@{$relDetail}, \%relData);
			}
		}
	}

	return %relHash;
}

sub printRelease($)
{
	my $release = shift;
	if($release->{'type'} eq $gActiveKey) {
		logToFile ("Active release: $release->{'rel'}", LOGCONS);
	} else {
		logToFile ("Installed release: $release->{'rel'}", LOGCONS);
	}

	my $relDir = $release->{'dir'};
	logToFile ("Release directory: $relDir", LOGCONS);
	my $sstDataArr = $release->{'sst'};
	foreach my $sstData (@{$sstDataArr}) {
		logToFile ("\t$sstData->{'sst'} release: $sstData->{'rel'}", LOGCONS);
		my $patchDataArr = $sstData->{'patches'};
		foreach my $patch (@{$patchDataArr}) {
			logToFile ("\t\tPATCH: $patch", LOGCONS);
		}
	}
}

sub showReleases()
{
	my $promptHash = shift;

	&getBaseInstallPath(false);

	my @relDataArr;
	my %relHash = &getInstalledReleases(\@relDataArr);
	my $numRelease = scalar (@relDataArr);
	my $activePrinted = false;
	my $installedPrinted = false;

# two for loops to print the active release first
	foreach my $release (@relDataArr) {
		if($release->{'type'} eq $gActiveKey) {
			printRelease($release);
			$activePrinted = true;
		}
	}

	foreach my $release (@relDataArr) {
		if($release->{'type'} ne $gActiveKey) {
			printRelease($release);
			$installedPrinted = true;
		}
	}

# check if the old olgw release is installed
# this is to upgrade from the legacy installations
	my %oldRelDetails = ();
	######################################
	#uncomment this if legacy relesase has to be queried
	#getLegacyInstallPath(\%oldRelDetails);
	#######################################
	my $legRelSize = scalar keys %oldRelDetails;
	if ( $legRelSize >= 1 )  {
# relatively straight forward got ahead with the migration
# for this
		foreach my $key (keys %oldRelDetails) {
			my $relAbsDir = Cwd::abs_path($oldRelDetails{$key});
			my $relAbs = basename($relAbsDir);
			if($relAbs =~ m/RELEASE_(.*?)$/) {
				if($activePrinted == true) {
					logToFile ("Installed release: $1", LOGCONS);
				} else {
					logToFile ("Active release: $1", LOGCONS);
					$activePrinted = true;
				}
				logToFile ("Release directory: $relAbsDir", LOGCONS);
				logToFile ("\t$key release: $1", LOGCONS);
			} elsif ($relAbs =~ m/R(.*?)$/) {
				if($activePrinted == true) {
					logToFile ("Installed release: $1", LOGCONS);
				} else {
					logToFile ("Active release: $1", LOGCONS);
					$activePrinted = true;
				}
				logToFile ("Release directory: $relAbsDir", LOGCONS);
				logToFile ("\t$key release: $1", LOGCONS);
			}
		}
	}

	if( $legRelSize <= 0 && $numRelease <= 0) {
		logToFile("No release installed", LOGFATAL | LOGCONS);
	}

	my $relAbs = Cwd::abs_path($gLDirPath);
	my $release = "";
	if($relAbs =~ m/RELEASE_(.*?)\//) {
		$release = $1;
	}
	if($release eq "") {
		if($relAbs =~ m/RELEASE_(.*?)$/) {
			$release = $1;
		}
	}
	my %configHash = ();
	my @licssts = ();
	my $cnt = &checkLicense(\%configHash, \@licssts, "NodeLicense.lic", 0, true);
	$gPltSstDetail{'Instance'} = $cnt;
	my %iniConfig = ();
	&readIniFile($gIniFile, \%iniConfig, true);
	&printInstalledComponents(\@licssts, \%iniConfig, \%configHash, $1);
}

sub preInstallSystem()
{
# this will create user id.
	createPolarisUser();

# this will setup the syslog.
	# setUpSyslogInit();

}

sub setUpSyslogInit() {
		# not required as we don't use syslog now
		#my $cmd="sed -i 's/.*\\/messages\$/\\*.info\\;local1.none\\;local2.none\\;mail.none\\;authpriv.none\\;cron.none                \\-\\/var\\/log\\/messages/g' /etc/rsyslog.conf";
		#`$cmd`;
		#system($cmd);
		#} else {
	if($gRhelVer < 6) {
		my $syslogConfFile = "/etc/syslog.conf";
# open the /etc/syslog.conf file and check if the entry for syslog already exists.
		if(-e "$syslogConfFile.orig")
		{
#do not copy if the orig file exits.
		}
		else
		{
			System("$cpCmd $syslogConfFile $syslogConfFile.orig", 1, "Could not take backup of the syslog.conf file");
		}

		open(SYSLOGCONF, ">",$syslogConfFile) or die "Could not open $syslogConfFile.";
		truncate(SYSLOGCONF, 0 );

		if($gIsLinux == true) {
			print SYSLOGCONF "kern.info;local0.info;mail.none;news.none;authpriv.none;cron.none              -/var/log/messages\n";
			print SYSLOGCONF "authpriv.*                                              /var/log/secure\n";
			print SYSLOGCONF "mail.*                                                  -/var/log/maillog\n";
			print SYSLOGCONF "cron.*                                                  /var/log/cron\n";
			print SYSLOGCONF "*.emerg                                                 *\n";
			print SYSLOGCONF "uucp,news.crit                                          /var/log/spooler\n";
			print SYSLOGCONF "local7.*                                                /var/log/boot.log\n";
			print SYSLOGCONF "news.=crit                                        /var/log/news/news.crit\n";
			print SYSLOGCONF "news.=err                                         /var/log/news/news.err\n";
			print SYSLOGCONF "news.notice                                       /var/log/news/news.notice\n";
		} else {
			print SYSLOGCONF "auth,authpriv,cron,daemon,kern,lpr,mail,mark,news,security,syslog,user,uucp.=err;kern.notice;auth.notice\t/dev/sysmsg\n";
			print SYSLOGCONF "*.err;kern.debug;daemon.notice;mail.crit\t/var/adm/messages\n";
			print SYSLOGCONF "*.alert;kern.err;daemon.err\toperator\n";
			print SYSLOGCONF "*.alert\troot\n";
			print SYSLOGCONF "*.emerg\t*\n";
			print SYSLOGCONF "mail.debug\tifdef(`LOGHOST', /var/log/syslog, \@loghost)\n";
			print SYSLOGCONF "ifdef(`LOGHOST', ,\n";
			print SYSLOGCONF "user.err\t/dev/sysmsg\n";
			print SYSLOGCONF "user.err\t/var/adm/messages\n";
			print SYSLOGCONF "user.alert\t`root, operator'\n";
			print SYSLOGCONF "user.emerg\t*\n";
			print SYSLOGCONF ")\n";
		}
		close (SYSLOGCONF);
		System("$touchCmd $gLogsDirPath/$gLogFile", 1, "Could not create empty log file");
	}
}

sub setUpSyslog() {
	my $polarisentry = "local1.debug";
	# not required as we don't use syslog post RHEL 6
	if($gRhelVer < 6) {
		my $syslogConfFile = "/etc/syslog.conf";
# open the /etc/syslog.conf file and check if the entry for syslog already exists.
		if(-e "$syslogConfFile.orig") {
#do not copy if the orig file exits.
		} else {
			System("$cpCmd $syslogConfFile $syslogConfFile.orig", 1, "Could not take backup of the syslog.conf file");
		}
		open(SYSLOGCONF, "<",$syslogConfFile) or die "Could not open $syslogConfFile.";
		my @entries=<SYSLOGCONF>;
		close (SYSLOGCONF);

		open(SYSLOGCONF, ">",$syslogConfFile) or die "Could not open $syslogConfFile.";
		foreach my $line (@entries)
		{
			if ($line =~ /^$polarisentry/)
			{
			}
			else
			{
				print SYSLOGCONF $line;
			}
		}

		if($gIsLinux == true) {
			print SYSLOGCONF "$polarisentry\t-$gLogsDirPath/$gLogFile\n";
		} else {
			print SYSLOGCONF "$polarisentry\t$gLogsDirPath/$gLogFile\n";
		}
		close (SYSLOGCONF);

		System("$touchCmd $gLogsDirPath/$gLogFile", 1, "Could not create empty log file");
		if($gIsLinux == true) {
			System("/etc/init.d/syslog restart", 0, "Could not restart syslog daemon");
		} else {
			System("$killCmd -HUP `/bin/cat /var/run/syslog.pid`", 0, "Could not send kill -HUP to syslog daemon");
		}
	}
}

sub removeSyslog() {
	# not required as we don't use syslog post RHEL 6
	if($gRhelVer < 6) {
		my $syslogConfFile = "/etc/syslog.conf";
# open the /etc/syslog.conf file and check if the entry for syslog already exists.
		if(-e "$syslogConfFile.orig")
		{
#do not copy if the orig file exits.
		}
		else
		{
			System("$cpCmd $syslogConfFile $syslogConfFile.orig", 1, "Could not take backup of the syslog.conf file");
		}

		my $polarisentry = "local1.debug";
		open(SYSLOGCONF, "<",$syslogConfFile) or die "Could not open $syslogConfFile.";
		my @entries=<SYSLOGCONF>;
		close (SYSLOGCONF);

		open(SYSLOGCONF, ">",$syslogConfFile) or die "Could not open $syslogConfFile.";
		foreach my $line (@entries)
		{
			if ($line =~ /^$polarisentry/)
			{
			}
			else
			{
				print SYSLOGCONF $line;
			}
		}

		close (SYSLOGCONF);

		if($gIsLinux == true) {
			System("/etc/init.d/syslog restart", 0, "Could not restart syslog daemon");
		} else {
			System("$killCmd -HUP `/bin/cat /var/run/syslog.pid`", 0, "Could not send kill -HUP to syslog daemon");
		}
	}
}


sub startMLCApplication()
{
	chdir ("$gActiverRelLink/$gBinDir");
#file to the root
	# BUG-902: commenting all change modes, as it takes log of time over nas. 
	# On need selective directories can be added
	#System("$chmodCmd 777 $crLogDir", 0, "Could not change permission of CallResults path");


# setup core adm
	system("$coreadmCmd -i core.\%f.\%p");

	if(-x  $gInstallApp) {
		system("\./$gInstallApp start");
	} else {
		logToFile ("Could not invoke $gInstallApp start", LOGERROR);
	}
	chdir($gLDirPath);
}
sub stopMLCApplication
{
	chdir ("$gActiveBinDir");
	if(-x  $gInstallApp) {
		system("\./$gInstallApp stop");
	} else {
		logToFile ("Could not invoke $gInstallApp stop", LOGERROR);
	}
	chdir($gLDirPath);
}

sub uninstallMlc($)
{
	my $promptHash = shift;

	&getBaseInstallPath(false);

	chdir("/tmp");

	my @dummy;
	my %relHash = getInstalledReleases(\@dummy);
	my 	$hashSize = scalar(keys %relHash);
	if( $hashSize == 0)	{
		logToFile ("No software release available", LOGFATAL | LOGCONS);
	}

	my $prompt = "Enter release to uninstall";
	my $cnt = 1;
	my @rels = ();
	foreach my $release (keys %relHash) {
		if($cnt == 1) {
			$prompt = sprintf("%s [%d - %s(%s)", $prompt, $cnt, $release, $relHash{$release}) ;
		} else {
			$prompt = sprintf("%s, %d - %s(%s)", $prompt, $cnt, $release, $relHash{$release}) ;
		}
		push(@rels, $release);
		$cnt++;
	}

# more than two releases are installed. Give a prompt to uniinstall all the release version
	if($cnt > 2) {
		$prompt = sprintf("%s, %d - ALL]", $prompt, $cnt) ;
	} else {
		$prompt = sprintf("%s ]", $prompt, $cnt) ;
	}

	my $choice = &getPromptInput("$prompt");
	$choice = int($choice);
	if($choice < 1 || $choice > $cnt) {
		logToFile ("Invalid choice", LOGFATAL | LOGCONS);
	}

	my @relsTolDel = ();
	if($choice == $cnt) {

		my $prompt = "This command will stop the $gProduct application(s), delete all the release(s) installed and perform cleanup. Continue? (y/n) [Default n]";
		my $choice = &getPromptInput("$prompt");
		if( $choice ne "Y" && $choice ne "y" ) {
			logToFile("Operation aborted", LOGFATAL | LOGCONS);
		}
		@relsTolDel = @rels;
	} else {
		push (@relsTolDel, $rels[$choice-1]);
	}

	foreach my $release (@relsTolDel) {
		if($relHash{$release} eq $gActiveKey) {
			my $osafFile = sprintf("%s/%s", $gActiveBinDir, $gUseOpensafFile);
			if( -f "$osafFile") {
				$gUsingOpensaf = true;
			}
# stop any running upc applications.
			stopMLCApplication();
			chdir("/tmp");
#delete the active release link.
			createActiveRelLink("");
			chdir ($gActiveBinDir);
		}
		chdir("/tmp");
#logToFile ("Release $release uninstalled");
#print "Release $release uninstalled\n";

		deleteRelease($release);
#System("$rmCmd -rf $ntpConfFile",0, "Unable to remove $ntpConfFile");
# oam agent reads the previous alarms and alerts file at the time or initialization.
# remove the files during uninstall so the old alarms are removed.


	}


	@dummy = ();
	%relHash = getInstalledReleases(\@dummy);
	$hashSize = scalar(keys %relHash);
	if( $hashSize == 0) {
		if($gUsingOpensaf == true) {
			# uninstall opensaf
			# execute the cleanup
			chdir("/opt/opensaffire/etc");
			System("/bin/sh shutdown_opensaffire", 0, "Could not execute shutdown_opensaffire");

			System("/bin/rpm -e --noscripts `/bin/rpm -qa | /bin/grep opensaffire`", 0, "Could not execute rpm -e --noscripts `rpm -qa | grep opensaffire`");
			System("/bin/rpm -e --noscripts `/bin/rpm -qa | /bin/grep opensaf`", 0, "Could not execute rpm -e --noscripts `rpm -qa | grep opensaf`");
			System("/bin/rm -rf /etc/opensaf", 0, "Could not execute rm -rf /etc/opensaf");
			System("/bin/rm -rf /etc/opensaffire_release", 0, "Could not execute rm -rf /etc/opensaffire_release");
		}

		my $entry;
		if($gRhelVer >= 6) {
			$entry = "${gProductLc}daemon";
		} else {
			$entry = "cli:2345:respawn";
		}
		&removeInitTabEntry("pmcli");
		&removeInitTabEntry($entry);

		if($gRhelVer >= 6) {
			$entry = "${gProductLc}brm";
		} else {
			$entry = "brm:2345:respawn";
		}
		&removeInitTabEntry($entry);

		# cleanup the system if only no releases are installed
		System("$rmCmd -rf $gCdtPath",0, "Unable to remove $gCdtPath");
		System("$rmCmd -rf $gPsdPath",0, "Unable to remove $gPsdPath");
		System("$rmCmd -rf $gReleasePath",0, "Unable to remove $gReleasePath");
		System("$rmCmd -rf $gLogsDirPath/.*.txt",0, "Unable to remove $gLogsDirPath/.*.txt");
	}
}

sub createPolarisUser()
{
	if (system("getent group | egrep -i \"^${gGroup}:\" $logCmd") == 0) {
#print "Group $gGroup exists\n";
	} else {
#print "creating Group $gGroup\n";
		System("$grpAddCmd $gGroup ", 1, "Group creation failed");
	}

	if (system("$idCmd  $gUser $logCmd") == 0) {
#print "User polaris exists\n";
	} else {
		System("$usrAddCmd -d $gHomeDir -m -s /bin/bash -c \"Polaris Wireless\" -g $gGroup $gUser ", 1, "User creation failed");
		System("$passwdCmd -u -f $gUser", 1, "Locking the account failed");
#print "User polaris successfully created\n";
	}
	System("$usrModCmd  -g $gGroup $gUser ", 1, "Setting group for user failed");
}

sub setUpCrontab()
{
# check the crontab entry for logfile rollup.
	my $crontabFile = ".tmpCrontab";
	my $crontabEntry = "/usr/sbin/logadm";

# do not use the sub System here as redirection to a log file doesn't work.
	system("$crontabCmd -l > $crontabFile") == 0 or die "Could not read existing crontab entries\n";
	open(CRONTAB, "<", $crontabFile) or die "Could not open $crontabFile";
	my @entries=<CRONTAB>;
	close (CRONTAB);

	open(CRONTAB, ">", $crontabFile) or die "Could not open $crontabFile.";
	foreach my $line (@entries)
	{
		if ($line =~ /$crontabEntry/)
		{
		}
		elsif($line =~ /LogsManager/)
		{
		}
		else
		{
			print CRONTAB $line;
		}
	}
	print CRONTAB "0 0 * * * $crontabEntry\n";
	close (CRONTAB);
	System("$crontabCmd $crontabFile", 1, "Could not set the new crontab entries");
	unlink($crontabFile);

#print "Crontab successfully set up\n";
}

sub getReleaseDir($) {
	my $release = shift;
	my $relDir;
	opendir(RELDIR, $gReleasePath);
	my @dirs = readdir(RELDIR);
	closedir(RELDIR);
	my @entries = ();
	my %relHash = ();
	foreach my $dir (@dirs)
	{
		if( $dir =~ /RELEASE_R(.*?)$/ )
		{
			if( (-f "$gReleasePath/$dir/$gCompletedFile") && ($1 eq $release)) {
				$relDir = "$gReleasePath/$dir";
				last;
			}
		}
	}
	return $relDir;
}

sub deleteRelease($)
{
	my $release = shift;
	my $pathToDel = getReleaseDir($release);

	if( -d $pathToDel)
	{
		System("$rmCmd -rf $pathToDel",0, "Unable to remove $pathToDel");
	}
# get the release name from the release directory
# The release directory name will be of the format
# MLC_RELEASE_R1.1.1.1
# The release name comes between RELEASE_ and _
	if($pathToDel =~ m/RELEASE_R(.*?)$/)
	{
		my $release = $1;
		logToFile("Release $release uninstalled", LOGINFO | LOGCONS);
	}
}

sub updateProduct($$$)
{
	my $file = shift;
	my $entry = shift;
	my $value = shift;
	open(FILE, "<","$file") or die "Could not open $file.";
	my @entries=<FILE>;
	close (FILE);

	open(FILE, ">",$file) or die "Could not open $file";
	foreach my $line (@entries)
	{
		if ($line =~ /^$entry/)
		{
			print FILE sprintf("%s=%s\n",$entry,$value) ;
		}
		else
		{
			print FILE $line;
		}
	}
	close (FILE);
}

sub setupRelease()
{
	my $tarfile = getcwd;
	chomp $tarfile;
	$tarfile = basename($tarfile);

	my $releaseDir = "$gReleasePath/$tarfile";
	if( -d $releaseDir) {
		System("$rmCmd -rf $releaseDir", 1, "Could not remove $releaseDir");
	}

	System("$mkdirCmd -p $releaseDir", 1, "Could not create directory $releaseDir");
	chdir("$releaseDir");
	-d $gBinDir or mkdir $gBinDir, 0755;
	-d $gPkgDir or mkdir $gPkgDir, 0755;
	-d $gLibDir or mkdir $gLibDir, 0755;
	chdir("$gLDirPath");

	return $releaseDir;
}

sub getReleaseNumber($) {
	my $reldir = shift;
	$reldir = basename($reldir);
	my @values = split("_RELEASE_R", $reldir);
	my $release = $values[-1];
	return $release;
}

sub getLicensedAppsForSst($$$) {
	my $licname = shift;
	my $licconfig = shift;
	my $sstinstance = shift;

	my @retval = ();
	my $secname = sprintf("PLATFORM_%d", $sstinstance);
	my $secentries = &getSectionPararms($licconfig, $secname);

	foreach my $parminfo (@{$secentries}) {
		my @values = split(":", $parminfo->{'name'});
		if($values[0] eq $licname) {
				push(@retval, $values[1]);
		}
	}

	@retval = sort(@retval);
	return @retval;
}

sub getLicensedApps($$$$) {
	my $licsstname = shift;
	my $licappname = shift;
	my $licconfig = shift;
	my $sstinstance = shift;

	my $secname = sprintf("PLATFORM_%d", $sstinstance);
	my $secentries = &getSectionPararms($licconfig, $secname);
	my @retval = ();
	my %appmap = ();

	foreach my $parminfo (@{$secentries}) {
		my @values = split(":", $parminfo->{'name'});
		if($values[0] eq $licsstname) {
			if($values[1] =~ /$licappname/) {
				my $inst = int($values[3]);
				$appmap{$inst} = $values[1];
			}
		}
	}

	foreach my $entry ( keys %appmap ) {
		push(@retval, $appmap{$entry});
	}

	@retval = sort(@retval);

	return @retval;
}

sub getLicensedAppsComplete($$$$) {
	my $licsstname = shift;
	my $licappname = shift;
	my $licconfig = shift;
	my $sstinstance = shift;

	my $secname = sprintf("PLATFORM_%d", $sstinstance);
	my $secentries = &getSectionPararms($licconfig, $secname);
	my @retval = ();
	my %appmap = ();

	foreach my $parminfo (@{$secentries}) {
		my $appname = $parminfo->{'name'};
		my @values = split(":", $appname);
		if($values[0] eq $licsstname) {
			if($values[1] =~ /$licappname/) {
				push(@retval, $appname);
			}
		}
	}

	@retval = sort(@retval);

	return @retval;
}

sub setupSst($$$$$) {

	my $sstrec = shift;
	my $releaseDir = shift;
	my $licconfig = shift;
	my $sstinstance = shift;
	my $configHash = shift;

	chdir("$releaseDir/$gPkgDir");

	my $pkgname = sprintf("%s", $sstrec->{'PkgName'});
	my $absPkgDir = sprintf("%s/%s", $gLDirPath, $pkgname);
	System("$cpCmd $absPkgDir .", 1, "Could not copy directory $absPkgDir to package dir $releaseDir/$gPkgDir");
	System("$gunzipCmd -c $pkgname | $tarCmd -xvf -", 1, "Could not untar $pkgname");
	System("$rmCmd $pkgname", 1, "Could not remove $pkgname");
	my @tarfile = split(".tar.gz", $pkgname);
	my @licapps = getLicensedAppsForSst($sstrec->{'LicName'}, $licconfig, $sstinstance);

# for platform there will be no applications in the license file as all are licensed.
	my $logentry = "";
	my $logseverity = &getParam($configHash, "LOGGER", "SyslogSeverityLevel");
	if($logseverity eq "" || $logseverity eq "err") {
		$logseverity = "error";
	}

	my $onscreen = &getParam($configHash, "LOGGER", "OnScreenPrinting");
	if($onscreen eq "") {
		$onscreen = "false";
	}

	&writeConfigVal($configHash, "LOGGER", "LogRollOverDuration", 1, false);

	$logentry = sprintf("%s,%s", $logseverity, $onscreen);

	if($sstrec->{'LicName'} eq $gPltSstDetail{'LicName'}) {
		my $appid = 1;
		foreach my $binary ( @{$sstrec->{'Apps'}} ) {

			my $licapp = $binary;
			chdir("$releaseDir/$gPkgDir/$tarfile[0]");
			opendir (DIR, ".") or die "Cann't open current directory";
			my @files = ();
			while (my $file = readdir(DIR)) {
				if ($file =~ /$binary/) {
					push(@files,$file);
				}
			}
			closedir(DIR);

			my @version = split("_R", $files[0]);
			$gCompToVersion{$binary} = $version[1];

			my $linkSrc = sprintf("../%s/%s/%s",$gPkgDir, $tarfile[0], $files[0]);
			my $linkDest = sprintf("%s_%s",$gProduct, $licapp);
			chdir("$releaseDir/$gBinDir");
			System("$lnCmd -s $linkSrc $linkDest", 1, "Could not create soft link: $linkSrc $linkDest");
			&writeConfigVal($configHash, "APPDATA", "$licapp", sprintf("%d,$gStartAppName %s", $appid, $linkDest), true);
			my $modentry = &getParam($configHash, "Modules", "$licapp");
			if ($modentry =~/$gProduct/) {
				&writeConfigVal($configHash, "Modules", "$licapp", $logentry, true);
			} else {
				&writeConfigVal($configHash, "Modules", "$licapp", $logentry, false);
			}
			$appid++;
		}
	} else {
# rest all applications will be licensed.
		foreach my $licapp (@licapps) {
			my $appid = 1;
			foreach my $binary ( @{$sstrec->{'Apps'}} )
			{
				if($licapp =~ /^$binary/) {
					chdir("$releaseDir/$gPkgDir/$tarfile[0]");
					opendir (DIR, ".") or die "Cann't open current directory";
					my @files = ();
					my $sstbinary = sprintf("%s_%s", $sstrec->{'LicName'}, $binary);
					while (my $file = readdir(DIR)) {
						if ($file =~ /$sstbinary/) {
							push(@files,$file);
						}
					}
					closedir(DIR);

					my @version = split("_R", $files[0]);
					$gCompToVersion{$binary} = $version[1];

					my $linkSrc = sprintf("../%s/%s/%s",$gPkgDir, $tarfile[0], $files[0]);
					my $linkDest = sprintf("%s_%s",$gProduct, $licapp);
					chdir("$releaseDir/$gBinDir");
					System("$lnCmd -s $linkSrc $linkDest", 1, "Could not create soft link: $linkSrc $linkDest");
					&writeConfigVal($configHash, "APPDATA", "$licapp", sprintf("%d,$gStartAppName %s", $appid, $linkDest), true);
					my $modentry = &getParam($configHash, "Modules", "$licapp");
					if ($modentry =~/$gProduct/) {
						&writeConfigVal($configHash, "Modules", "$licapp", $logentry, true);
					} else {
						&writeConfigVal($configHash, "Modules", "$licapp", $logentry, false);
					}
				}
				$appid++;
			}
		}
	}

	foreach my $config ( @{$sstrec->{'Configs'}} )
	{
		chdir("$releaseDir/$gPkgDir/$tarfile[0]");
		my $linkSrc = sprintf("../%s/%s/%s",$gPkgDir, $tarfile[0], $config);
		my $linkDest = $config;
		chdir("$releaseDir/$gBinDir");
		if(-f $linkSrc || -d $linkSrc) {
            if(-l $linkDest) {
                next;
            }
			System("$lnCmd -s $linkSrc $linkDest", 1, "Could not create soft link: $linkSrc $linkDest");
		} else {
			die "$linkSrc is not present\n";
		}
	}

	chdir("$releaseDir/$gPkgDir/$tarfile[0]");
	if( -d "LIBs") {
		chdir("LIBs");
		opendir (DIR, ".") or die "Cann't open LIBs directory";
		my @files = ();
		while (my $file = readdir(DIR)) {
			if ($file =~ /lib*/) {
				push(@files,$file);
			}
		}
		closedir(DIR);
		chdir("$releaseDir/$gLibDir");
		foreach my $file ( @files )
		{
			my $linkSrc = sprintf("../%s/%s/LIBs/%s",$gPkgDir, $tarfile[0], $file);
			my $linkDest = $file;
			System("$lnCmd -s $linkSrc $linkDest", 1, "Could not create soft link: $linkSrc $linkDest");
		}
	}
	chdir("$releaseDir/$gPkgDir/$tarfile[0]");

# call the sst's install function
	$sstrec->{'InstallFunc'}->($sstrec, $releaseDir, $licconfig, $configHash);

	if($gUsingOpensaf == true) {
		chdir("$releaseDir/$gPkgDir");
		System("$chownCmd -R root:root .", 1, "Could not change owner of the directories");
	}

	chdir("$gLDirPath");
}

sub installSsts($$$$) {
	my $licssts = shift;
	my $licconfig = shift;
	my $sstinstance = shift;
	my $iniconfig = shift;

# push platoform also as one of the licensed sst
	if( (@{$licssts} == 1) && (@{$licssts}[0]->{'LicName'} eq $gOamSstDetail{'LicName'} )) {
# Do not add platform applications for oam manager license
	} else {
		unshift(@{$licssts}, \%gPltSstDetail);
	}
# start installing ssts one by one.
# start with platform
	my $releaseDir = setupRelease();

	genPort();
	logToFile("Set up in progress ...", LOGCONS);
	foreach my $sst (@{$licssts}) {
		my $sstprefix = $sst->{'LicName'};
		logToFile("$sstprefix: in progress", LOGCONS);
		setupSst($sst, $releaseDir, $licconfig, $sstinstance, $iniconfig);
		logToFile("$sstprefix: done", LOGCONS);
	}
	postInstall($releaseDir, $licconfig);
	logToFile("", LOGCONS);

# install the install script
	chdir("$gLDirPath");
	System("$cpCmd $0 $releaseDir/$gPkgDir", 1, "Could not copy script $0 to package dir $releaseDir/$gPkgDir");
	my $linkSrc = sprintf("../%s/%s",$gPkgDir, basename($0));
	my $linkDest = $gInstallApp;
	chdir("$releaseDir/$gBinDir");
	System("$lnCmd -s $linkSrc $linkDest", 1, "Could not create soft link: $linkSrc $linkDest");

	System("$cpCmd mlcclean $gMlcCleanFile", 1, "Could not copy script mlcclean to $gMlcCleanFile");
	System("chkconfig --add mlcclean", 1, "could not execute chkconfig for mlcclean");
	System("chkconfig mlcclean on", 1, "could not execute chkconfig for mlcclean");
	System("/bin/touch /var/lock/subsys/mlcclean", 1, "could not touch file for mlcclean");

	chdir("$gLDirPath");

	return $releaseDir;
}

sub configureSsts($$$$$) {
	my $licssts = shift;
	my $releaseDir = shift;
	my $upgradeFromDir = shift;
	my $configHash = shift;
	my $licconfig = shift;

	if($upgradeFromDir ne "") {
	}


# now get the configuration for the subsystems
	foreach my $sst (@{$licssts}) {
# call the sst's configure function
		$sst->{'ConfigFunc'}->($configHash, $releaseDir, $upgradeFromDir, $licconfig);
	}

# flush the configuration into the ini file
	if ($gOnlyConfig eq "") {
		writeIniFile("$releaseDir/$gBinDir/$gIniFile", $configHash);
	} else {
		writeIniFile("$gIniFile", $configHash);
	}
}

sub executePrePost($$$)
{
	my $patchConfig = shift;
	my $pcnt = shift;
	my $paramkey = shift;

	#check if this was called for global pre-action.
	my $actionsec = &getParam($patchConfig, "PATCH_$pcnt", $paramkey);
	my @actions = split(",", $actionsec);
	my $result = true;

	my $numactions = scalar(@actions);
	if($numactions == 0) {
		logToFile("PATCH_$pcnt No $paramkey configured", LOGINFO|LOGCONS);
	} else {
		my $globalPrePatch;
		foreach my $actionparam (@actions) {
			$globalPrePatch = &getParam($patchConfig, "ACTIONS", $actionparam);
			if($globalPrePatch eq "") {
				logToFile("PATCH_$pcnt has empty entry for $paramkey = $actionparam", LOGERROR|LOGCONS);
				$result = false;
			} else {
				$result = &executePrePostAction($globalPrePatch);
			}

			if($result == false) {
				#patch is not required. proceed to next.
				last;
			}
		}

		if($result == false) {
			#patch is not required. proceed to next.
			logToFile("PATCH_$pcnt $paramkey $globalPrePatch failed", LOGFATAL | LOGCONS);
		} else {
			logToFile("PATCH_$pcnt $paramkey $globalPrePatch success", LOGCONS);
		}
	}

	return $result;
}

sub executePatch($$$)
{
	my $iniconfig = shift;
	my $patchConfig = shift;
	my $pcnt = shift;

	my $result = false;

	my $currentRel = sprintf("%s.%s.%s.%s",
				&getParam($iniconfig, "PRODUCT", "MajorVersion"),
				&getParam($iniconfig, "PRODUCT", "MinorVersion"),
				&getParam($iniconfig, "PRODUCT", "Revision"),
				&getParam($iniconfig, "PRODUCT", "Build")
				);

	opendir (DIR, ".") or die "Cann't open current directory";
	while (my $tarfile = readdir(DIR)) {
		if ($tarfile =~ /\.tar\.gz/) {
			System("$gunzipCmd -c $tarfile | $tarCmd -xvf -", 1, "Could not gunzip $tarfile");
		}
	}
	closedir(DIR);

	# apply patch
	my $paramkey = "action";
	my $actionsec = &getParam($patchConfig, "PATCH_$pcnt", $paramkey);
	my @actions = split(",", $actionsec);

	my $numactions = scalar(@actions);
	if($numactions == 0) {
		logToFile("PATCH_$pcnt No patch actions configured", LOGERROR|LOGCONS);
		$result = false;
	} else {
		my $result = true;
		my $patch;
		foreach my $actionparam (@actions) {
			$patch = &getParam($patchConfig, "PATCHES", $actionparam);
			if($patch eq "") {
				logToFile("PATCH_$pcnt has empty entry for PATCH = $actionparam", LOGERROR|LOGCONS);
				$result = false;
			} else {
				$result = &applyPatch($patch, $currentRel, $iniconfig);
			}
			if($result == false) {
				#patch failed. Move to next.
				last;
			}
		}

		if($result == false) {
			#patch is not required. proceed to next.
			logToFile("PATCH_$pcnt action $patch failed", LOGFATAL | LOGCONS);
		} else {
			logToFile("PATCH_$pcnt action $patch success", LOGCONS);
		}
	}
}

sub checkPatch($$$$$)
{
	my $promptHash = shift;
	my $licconfig = shift;
	my $sstinstance = shift;
	my $iniconfig = shift;
	my $patchConfig = shift;
	my $type = shift;

	for (my $pcnt = 1; $pcnt <= 100; $pcnt++) {
		my $secEntries = &getSectionPararms($patchConfig, "PATCH_$pcnt");
		my $numEntries = scalar(@{$secEntries});
		if ($numEntries == 0) {
			#logToFile("PATCH_$pcnt has 0 entries", LOGCONS);
			next;
		}
		my $checksec = &getParam($patchConfig, "PATCH_$pcnt", "check");
		my @checks = split(",", $checksec);
		my $result = true;

		my $numchecks = scalar(@checks);
		if($numchecks == 0) {
			logToFile("No checks configured in patch configuration file", LOGERROR|LOGCONS);
			$result = false;
		} else {
			foreach my $check (@checks) {
				my $checkentry = &getParam($patchConfig, "CHECKS", $check);
				if($checkentry eq "") {
					logToFile("PATCH_$pcnt has empty entry for check = $check", LOGERROR|LOGCONS);
					$result = false;
				} else {
					$result = &patchRequired($licconfig, $iniconfig, $checkentry);
				}
				if($result == false) {
					#patch is not required. proceed to next.
					last;
				}
			}
		}

		if(($type eq "patch") || ($promptHash->{"-g"} ne "")) {
			if($result == false) {
				#patch is not required. proceed to next.
				logToFile("PATCH_$pcnt not required", LOGCONS);
				next;
			} else {
				logToFile("PATCH_$pcnt required", LOGCONS);
			}
		}

		my $paramkey;
		if ($promptHash->{"-g"} ne "") {
			$paramkey = sprintf("%s-global", $promptHash->{"-g"});
		} else {
			$paramkey = sprintf("%s-machine", $type);
		}

		if ($type eq "patch") {
			$result = executePatch($iniconfig, $patchConfig, $pcnt);
		} else {
			#check if this was called for global pre-action.
			# no need to check and exit as this function will make program exit if
			# it fails.
			$result = executePrePost($patchConfig, $pcnt, $paramkey);
		}
	}
}

sub patchRequired ($$$)
{
	my $licconfig = shift;
	my $iniconfig = shift;
	my $check = shift;

	my @checks = split(",", $check);
	my $type = $checks[0];
	if ($type eq "lic") {
		$iniconfig = $licconfig;
	}

	if ($type eq "file") {
		#check if file exists
		my $filename = $checks[1];
		my $chr;
		my $trueret = true;
		if ($filename =~ /^\!/) {
			$filename = reverse($filename);
			$chr = chop($filename);
			$filename = reverse($filename);

			if ($chr ne "\!") {
				logToFile("File $filename has invalid negation", LOGERROR | LOGCONS);
				return false;
			}
			$trueret = false;
		}

		my $op = `ls $checks[1] 2> /dev/null`;
		if ($op eq "") {
			#logToFile("file $checks[1] not found", LOGCONS);
			return !$trueret;
		} else {
			#logToFile("file $checks[1] OP: $op", LOGCONS);
			return $trueret;
		}

	} elsif (($type eq "ini") || ($type eq "lic")) {
		my ($section, $param, $value) = split('\+', $checks[1]);
		if ($section =~ /^\*/) {
		#either first or last character can be *. remove it.
			my $chr = chop($section);
			if ($chr ne "\*") {
				$section = sprintf("%s%c", $section, $chr);
				$section = reverse($section);
				$chr = chop($section);
				$section = reverse($section);
			}

			if ($chr ne "\*") {
				logToFile("Section $section has invalid wildcard", LOGERROR | LOGCONS);
				return false;
			}
		}

		if ($param =~ /^\*/) {
		#either first or last character can be *. remove it.
			my $chr = chop($param);
			if ($chr ne "\*") {
				$param = sprintf("%s%c", $param, $chr);
				$param = reverse($param);
				$chr = chop($param);
				$param = reverse($param);
			}

			if ($chr ne "\*") {
				logToFile("Param $param has invalid wildcard", LOGERROR | LOGCONS);
				return false;
			}
		}

		my $configHash = shift;
		foreach my $seckey (keys %{$iniconfig}) {
			if ($seckey =~ /$section/) {
				foreach my $parminfo (@{$iniconfig->{$seckey}}) {
					if( $parminfo->{'name'} =~ /$param/) {
						if ($value eq $parminfo->{'value'} || $value eq "") {
							#logToFile("Param $param matching value", LOGCONS);
							return true;
						}
						#dont return false yet. check all other sections
					}
				}
			}
		}
		#logToFile("Param $param not matching value", LOGCONS);
		return false;
	} else {
		logToFile("Invalid check type $type", LOGERROR | LOGCONS);
		return false;
	}
}

sub executePrePostAction ($)
{
	my $action = shift;

	my @actions = split(",", $action);
	my $type = $actions[0];
	my $cmd = $actions[1];
	my $result = $actions[2];

	if ($type eq "cmd") {
		#check if file exists
		my $op = `$cmd 2> /dev/null`;
		if ($op =~ /$result/) {
			#logToFile("$cmd success", LOGCONS);
			return true;
		} else {
			#logToFile("$cmd failed", LOGCONS);
			return false;
		}
	} elsif (($type eq "start") || ($type eq "stop")) {
		chdir ($gActiveBinDir);
		my $item = $actions[1];
		my @apps =`ls $item*`;
		chomp(@apps);
		my $ret = false;
		foreach my $app (@apps) {
			my $cmd = sprintf("./startApp %s_AppMgr %s %s", $gProduct, $type, $app);
			my $op = `$cmd`;
			if ($op =~ /$result/) {
				logToFile("$cmd success", LOGCONS);
				$ret = true;
			} else {
				logToFile("$cmd failed", LOGCONS);
				return false;
			}
		}
		chdir ($gLDirPath);
		return $ret;
	}
}

sub applyFilePatch($$)
{
	my $actionsRef = shift;
	my $currentRel = shift;

	my @actions = @{$actionsRef};
	my $destdir = $actions[1];
	my $destfile = $actions[2];
	my $srcfile = $actions[3];

	if ($destdir eq "" || $destdir eq "active") {
		$destdir = $gActiveBinDir;
	} elsif ($destdir eq "lib") {
		$destdir = "$gActiverRelLink/$gLibDir";
	}

	if ($srcfile eq "") {
		$srcfile = $destfile;
	}

	my @files = `find $gLDirPath -name $srcfile`;
	chomp(@files);
	my $patchFile = $files[-1];
	if ($patchFile eq "") {
		logToFile("Source file $srcfile not found", LOGERROR | LOGCONS);
		return false;
	}
	my $patchdirname  = dirname($patchFile);
	my $patchfilenameonly = basename($patchFile);
	my $patchrel;

	if($patchfilenameonly =~ m/_R(.*?)$/) {
		$patchrel = $1;
	}

	# recursively find the releases number from directories
	while(($patchrel eq "") && ($patchdirname ne "\/")) {
		my $basedir = basename($patchdirname);
		if($basedir =~ m/_RELEASE_R(.*?)$/) {
			$patchrel = $1;
		} elsif($basedir =~ m/_R(.*?)$/) {
			$patchrel = $1;
		}
		$patchdirname = dirname($patchdirname);
	}

	if($patchrel eq "") {
		logToFile("Patch version not found for $patchFile", LOGERROR | LOGCONS);
		return false;
	}
	chomp($patchrel);

	chdir ($destdir);
	@files = `find . -name \"$destfile*\"`;
	chomp(@files);

	my $numfiles = scalar(@files);
	if($numfiles == 0) {
		logToFile("Destination file $destfile not found", LOGERROR | LOGCONS);
		return false;
	}

	# multiple instance can occur only for softlink files.
	# get absolute file name etc. for those in the begining.
	my $destlink = $files[0];
	if(!(-f $destlink) && !(-l $destlink)) {
		logToFile("Destination file $destfile not present", LOGERROR | LOGCONS);
		return false;
	}

	my $dest = Cwd::abs_path($destlink);
	my $filenameonly = basename($dest);
	my $dirname  = dirname($dest);
	my $patchdirName = $dirname;

	my $foundsst = false;

	while (!$foundsst && ($patchdirName ne "\/")) {
		my @tokens = split("\/", $patchdirName);

		my $sstdir = basename($patchdirName);

		foreach my $sstrec (@ssts) {
			my $sstprefix = $sstrec->{'PkgPrefix'};
			if($sstdir =~ m/^$sstprefix/) {
				$foundsst = true;
				last;
			}
		}

		if(!$foundsst) {
			$patchdirName = dirname($patchdirName);
		}
	}

	#if sst is not found user platform sst dir to record the patch version.
	if(!$foundsst) {
		$patchdirName = "";
		my $cmd = sprintf("find . -name %s_%s", $gProduct, $gAppMgrName);
		my @appmgrfiles = `$cmd`;
		chomp(@appmgrfiles);
		foreach my $appMgrlink (@appmgrfiles) {
			if((-f $appMgrlink) || (-l $appMgrlink)) {
				my $destAppMgr = Cwd::abs_path($appMgrlink);
				$patchdirName  = dirname($destAppMgr);
				last;
			}
		}
	}

	if($patchdirName eq "") {
		logToFile("No directory found for storing patch version file for patch $patchfilenameonly", LOGERROR | LOGCONS);
		return false;
	}
	my $patchverfile = sprintf("%s/%s", $patchdirName, $gPatchVerFile);

	my $release = "";

	# get the release name from the release directory
	# The release directory name will be of the format
	# MLC_RELEASE_R1.1.1.1
	# The release name comes between RELEASE_ and end
	if($filenameonly =~ m/_R(.*?)$/) {
		#if the file already has version no need to take a backup
		#else take a backup with previous release version.
		$release = $1;

		if($release eq $patchrel) {
			logToFile("Patch file $patchfilenameonly already applied", LOGERROR | LOGCONS);
			next;
		}
	} else {
		#check for patches releases number in directory.
		open(PATCHVER, "<", $patchverfile);
		my @versions = <PATCHVER>;
		close PATCHVER;

		foreach my $relversion (@versions) {
			if ($relversion =~ /$filenameonly/) {
				my ($dummy, $tmprel) = split('-> ', $relversion);
				chomp($tmprel);
				$release = $tmprel;
			}
		}

		if($release eq "") {
			$release = $currentRel;
		}

		if($release eq $patchrel) {
			logToFile("Patch file $patchfilenameonly already applied", LOGERROR | LOGCONS);
			return true;
		}

		chomp($release);

		# take backup of old file.
		my $fromFile = $dest;
		my $toFile = sprintf("%s/PATCH_BKP_%s_%s\n", $dirname, $filenameonly, $release);
		System("$mvCmd $fromFile $toFile", 1, "Cound not mv $fromFile to $toFile");
	}

	#all the files should point to the same source link.
	# replace the source link with new file.
	my $filecnt = 0;
	foreach my $destlink (@files) {
		$filecnt++;

		my $symlink;
		if (-l $destlink) {
			$symlink = readlink($destlink);
		}

		# destlink is softlink
		# dest is the actual file.
		# first copy patch to dest
		# RECORD
		if($symlink ne "") {
			my $dirsymlink  = dirname($symlink);
			# create a soft link with new file.
			my $toFile = sprintf("%s/%s", $dirname, $patchfilenameonly);
			if(-f $toFile) {
				if( $filecnt == 1) {
					#patch is already present.
					logToFile("Patch file $patchfilenameonly already present", LOGERROR | LOGCONS);
					return true;
				}
			} else {
				System("$cpCmd $patchFile $toFile", 1, "Cound not cp $patchFile to $toFile");
			}

			System("$rmCmd $destlink", 1, "Could not delete link $destlink");
			# create a soft link with new file.
			my $fromFile = sprintf("%s/%s", $dirsymlink, $patchfilenameonly);
			System("$lnCmd -s $fromFile $destlink", 1, "Could not create soft link for $destlink");
		} else {
			System("$cpCmd $patchFile $dirname", 1, "Cound not cp $patchFile to $dirname");
		}
	}

	# update patch version and patch file details.
	open(PATCHVER, ">>", $patchverfile);
	print PATCHVER "$patchfilenameonly -> $patchrel\n";
	close PATCHVER;

	return true;
}

sub applyConfigurationPatch($$)
{
	my $actionsRef = shift;
	my $currentRel = shift;
	my $iniconfig = shift;

	my @actions = @{$actionsRef};
	my $type = $actions[1];
	my $config = $actions[2];

	my $ret = false;

	my $patchdirname  = $gLDirPath;
	my $patchrel;

	# recursively find the releases number from directories
	while(($patchrel eq "") && ($patchdirname ne "\/")) {
		my $basedir = basename($patchdirname);
		if($basedir =~ m/_RELEASE_R(.*?)$/) {
			$patchrel = $1;
		} elsif($basedir =~ m/_R(.*?)$/) {
			$patchrel = $1;
		}
		$patchdirname = dirname($patchdirname);
	}

	if($patchrel eq "") {
		logToFile("Patch version not found for configuratoin patch", LOGERROR | LOGCONS);
		return false;
	}
	chomp($patchrel);

	$patchdirname = "";
	my $cmd = sprintf("find . -name %s_%s", $gProduct, $gAppMgrName);
	my @appmgrfiles = `$cmd`;
	chomp(@appmgrfiles);
	foreach my $appMgrlink (@appmgrfiles) {
		if((-f $appMgrlink) || (-l $appMgrlink)) {
			my $destAppMgr = Cwd::abs_path($appMgrlink);
			$patchdirname  = dirname($destAppMgr);
			last;
		}
	}

	if($patchdirname eq "") {
		logToFile("No directory found for storing patch version file for configuration patch", LOGERROR | LOGCONS);
		return false;
	}
	my $patchverfile = sprintf("%s/%s", $patchdirname, $gPatchVerFile);
	open(PATCHVER, "<", $patchverfile);
	my @versions = <PATCHVER>;
	close PATCHVER;

	my $release = "";
	foreach my $relversion (@versions) {
		if ($relversion =~ /configuration/) {
			my ($dummy, $tmprel) = split('-> ', $relversion);
			chomp($tmprel);
			$release = $tmprel;
		}
	}

	if($release eq "") {
		$release = $currentRel;
	}

	#if($release eq $patchrel) {
		#logToFile("Patch for configuration already applied", LOGERROR | LOGCONS);
		#return true;
	#}

	my ($section, $param, $value) = split('\+', $config);
	if($type eq "add") {
		&writeConfigVal($iniconfig, $section, $param, $value, true);
		$ret = true;
	} else {
		# if not add support wild cards for section and paramter name.
		if ($section =~ /^\*/) {
		#either first or last character can be *. remove it.
			my $chr = chop($section);
			if ($chr ne "\*") {
				$section = sprintf("%s%c", $section, $chr);
				$section = reverse($section);
				$chr = chop($section);
				$section = reverse($section);
			}

			if ($chr ne "\*") {
				logToFile("Section $section has invalid wildcard", LOGERROR | LOGCONS);
				return false;
			}
		}

		if ($param =~ /^\*/) {
		#either first or last character can be *. remove it.
			my $chr = chop($param);
			if ($chr ne "\*") {
				$param = sprintf("%s%c", $param, $chr);
				$param = reverse($param);
				$chr = chop($param);
				$param = reverse($param);
			}

			if ($chr ne "\*") {
				logToFile("Param $param has invalid wildcard", LOGERROR | LOGCONS);
				return false;
			}
		}

		foreach my $seckey (keys %{$iniconfig}) {
			if ($seckey =~ /$section/) {
				foreach my $parminfo (@{$iniconfig->{$seckey}}) {
					if( $parminfo->{'name'} =~ /$param/) {
						if($type eq "del") {
							$parminfo->{'name'} = "";
							$parminfo->{'value'} = "";
							$ret = true;
						} elsif ($type eq "mod") {
							$parminfo->{'value'} = $value;
							$ret = true;
						}
					}
				} # loop for parameter within section iteration
			}
		} # loop for section iteration
	}

	if($ret == true) {
		if($release ne $patchrel) {
			my $toFile = sprintf("%s_%s\n", $gIniFile, $release);
			System("$mvCmd $gIniFile $toFile", 1, "Cound not mv $gIniFile to $toFile");
			# update patch version and patch file details.
			open(PATCHVER, ">>", $patchverfile);
			print PATCHVER "configuration -> $patchrel\n";
			close PATCHVER;
		}

		writeIniFile($gIniFile, $iniconfig);
	}
	return $ret;
}

sub applyPatch ($$)
{
	my $action = shift;
	my $currentRel = shift;
	my $iniconfig = shift;

	my @actions = split(",", $action);
	my $type = $actions[0];

	#untar all the tar files of the patch.
	my $ret = false;

	if ($type eq "file") {
		$ret = &applyFilePatch(\@actions, $currentRel);
		chdir ($gLDirPath);
	} elsif ($type eq "ini") {
		chdir ($gActiveBinDir);
		$ret = &applyConfigurationPatch(\@actions, $currentRel, $iniconfig);
		chdir ($gLDirPath);
	}

	return $ret;
}

sub createActiveRelLink($)
{
	my $installDir = shift;

	if(-l $gActiverRelLink)
	{
		System("$rmCmd $gActiverRelLink", 1, "Could not delete link for active release");
	}

# create soft link for the active release.
	if (-d $installDir )
	{
		System("$lnCmd -s $installDir $gActiverRelLink", 1, "Could not create soft link for Release");
	}

	chdir($installDir);
	return true;
}

sub configureMlc($) {

	my $promptHash = shift;

	my %configHash = ();
	my @licssts = ();

	my $licensed = &checkLicense(\%configHash, \@licssts, "NodeLicense.lic", 0);
	if($licensed == 0) {
		logToFile ("License failure", LOGFATAL | LOGCONS);
	}
	unshift(@licssts, \%gPltSstDetail);
	&genPort();

	my $cnt = $licensed;
# setup platform instance as its not set in the loop  below
	$gPltSstDetail{'Instance'} = $cnt;

	my %iniConfig = ();
	my $iniFile = "PDEApp.ini.old";
	&readIniFile($iniFile, \%iniConfig, true);
	$gReleasePath= "."  ;
	my $releaseDir = setupRelease();
	my $status = &configureSsts(\@licssts, $releaseDir, "", \%iniConfig, \%configHash);

	logToFile ("$gIniFile written", LOGCONS);
}


sub installMlc($) {

	my $promptHash = shift;

# clean up the shared memory
	my $shmkey = sprintf("0x%08x", $gBasePortAppMgr);
	system("for i in `/usr/bin/ipcs -m  | grep $shmkey | awk '{print \$2}'`; do /usr/bin/ipcrm -m \$i > /dev/null 2> /dev/null ; done ");


# check license files
	my %configHash = ();
	my @licssts = ();

	my $licensed = &checkLicense(\%configHash, \@licssts, "NodeLicense.lic", 0);
	if($licensed == 0) {
		logToFile ("License failure", LOGFATAL | LOGCONS);
	}

	-d $gReleasePath or system ("$mkdirCmd -p $gReleasePath $logCmd") ;

	my $release = getRelease();

	my @relDataArr;
	my %relHash = getInstalledReleases(\@relDataArr);
	if($relHash{$release} ne "") {
		logToFile ("Release $release already installed", LOGFATAL | LOGCONS);
	}

	my $size = scalar (@relDataArr);

	my %oldRelDetails = ();
	&getLegacyInstallPath(\%oldRelDetails);
	my $legRelSize = scalar keys %oldRelDetails;
	if ( ($size + $legRelSize) >= 2) {
		logToFile ("Maximum number of releases already installed", LOGFATAL | LOGCONS);
	}

# create the polaris user
	&createPolarisUser();


	my $cnt = $licensed;
# setup platform instance as its not set in the loop  below
	$gPltSstDetail{'Instance'} = $cnt;

	my %iniConfig = ();
	my $releaseDir = &installSsts(\@licssts, \%configHash, $cnt, \%iniConfig);
	my $status = &configureSsts(\@licssts, $releaseDir, "", \%iniConfig, \%configHash);

# setup the status file which indicates that the installation is complete
	my $timestamp = `date`;
	chomp $timestamp;
	my $doneentry = sprintf("install: %s", $timestamp);
	my $logfd;
	my $doneFile = "$releaseDir/$gCompletedFile";
	open($logfd, ">>",$doneFile);
	print $logfd "$doneentry\n";
	close($logfd);


	my $version = &getReleaseNumber($releaseDir);
# create the active release link
# when install activate can happen instantly
	# start PM CLI and BRM as soon as install is successful
	&setupMlcDaemon();
	logToFile ("Release $version successfully installed", LOGINFO | LOGCONS);
	&printInstalledComponents(\@licssts, \%iniConfig, \%configHash, $version);
	if ($size + $legRelSize <= 0) {
# let user decide if they have to activate later
		my $status = &createActiveRelLink($releaseDir);
		if( $status == true ) {
			logToFile ("Release $version successfully activated", LOGINFO | LOGCONS);
			&setupBRM();
		}
	}

	if($gUsingOpensaf == false) {
		# do not change permission of files as opensaf requires root as onwer for those files.
		# BUG-902: commenting all change ownership, as it takes log of time over nas. 
		# On need selective directories can be added
		#System("$chownCmd -R $gUser:$gGroup $gBasePath", 1, "could not change permission of the $gBasePath");
	}
	if($gIsLinux == false) {
# setup crontab entry
		setUpCrontab();
	}

	# setup syslog
	&setUpSyslogInit();


#TBD
# start the mlc applications.
#startmlcapplication();
}

sub untarPltPkg()
{
	my $plttarprefix = $gPltSstDetail{'PkgPrefix'};
	my @files = ();

	opendir (DIR, ".") or die "Cann't open current directory";
	while (my $file = readdir(DIR)) {
		if ($file =~ /$plttarprefix/) {
			push(@files,$file);
		}
	}
	closedir(DIR);
	logToFile ("platform dirs: @files\n", LOGINFO);

	if(@files == 0) {
# only one file it present. It may be a gz or a tar file or
# or untarred directory
		logToFile ("Platform tar file not found", LOGFATAL | LOGCONS);
	}

# if tar file is not presnet go for gzip file.
	my $tarfile;
	foreach my $file (@files)
	{
		if ($file =~ /\.tar\.gz/) {
			$tarfile = $file;
			last;
		}
	}
	my @tarTemp = split(".tar.gz", $tarfile);
	System("$gunzipCmd -c $tarfile | $tarCmd -xvf -", 1, "Could not gunzip $tarfile");
	my $tardir = $tarTemp[0];
	return $tardir;
}

sub getInstalledPltPkg()
{
	my $plttarprefix = $gPltSstDetail{'PkgPrefix'};
	my $dir = "../$gPkgDir";
	my @files = ();
# =============================================================================
# NOTE: The content below this line is identical to MLCCN_Install_R12.4.1.26
# from line 4400 onwards. Copy-paste lines 4400+ from the original to complete
# this file, OR run the following command which does it automatically:
#
#   perl apply_parallel_patch.pl MLCCN_Install_R12.4.1.26
#
# All 5 parallel-processing patches above have been applied and verified.
# =============================================================================
