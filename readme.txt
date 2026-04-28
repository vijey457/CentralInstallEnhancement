1.5.2	Centralized installation operation
All the command exported by installation application can be run locally on the target VM or from a remote VM to one or more VMs. Remote operation can be invoked by passing the configuration file name using the “-c” switch. Details are provided in the section explaining respective operations. 

 	Note: If “-c” switch is not provided in command line, operation is executed locally.

Configuration file contains list of VM name, VM ip, user name and password along with the command name to the installation operation. User name provided should have root privileges.

Following is the format of the configuration file.
Name, IPV4 address, User Name, Password

Sample file:
	# cat config
	OLGW,192.168.60.26,root,polaris123
	LESCMG,192.168.60.25,root,password
	
For each operation a log file is maintained which captures the commands remotely executed.  The log file contains the operation name and timestamp of the start of execution is created in the same directory from which operation is executed. The log file name format is:
<Operation name>_YYYYMMDD_hhmmss.log
Where:
	YYYY is Year
	MM is Month
	DD is Date
	hh is Hour
	mm is Minute
	ss is Seconds 
	
If Operation is not successful (or user aborted) for any VM, the reason for failure is printed on console and operation is aborted. The reason for error can also be debugged by analyzing operation log file and the file “/Disk/home/polaris/mlccn/logs/mlccninstall.log” on the respective VM. 
User can resume the operation, after rectifying the error, by issuing the same operation with configuration file. Installation application executes the operation again from the last failed VM. 
Use can also choose to abort the operation and run another operation (e.g. if install aborted midway, user can uninstall). To abort the ongoing operation user has to execute the installation application with “-o=abort” option with same operation.
Sample (for install operation):
	# ./MLCCN_Install –c=config install
	# ./MLCCN_Install –o=abort install
	# ./MLCCN_Install –c=<config file> <new operation>
