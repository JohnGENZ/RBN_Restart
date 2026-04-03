The Reverse Beacon Network (RBN, https://www.reversebeacon.net/index.php) uses Aggregator.exe and SkimSrv.exe.  They can "crash" or "hang" at times of high processor load or network congestion.  This script will monitor the tasks and restart them if necessary.

Place the script in C:\Scripts and the batch file in your startup folder.  Please do not start the Aggregator and Skimmer directly; let the script handle it.  Create C:\Logs for the log.

Read the first few lines of the script carefully.  The path and file names are hard-coded and may need to be changed for your installation.
The same is true for the batch file.
