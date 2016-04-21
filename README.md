ncentral-logstash
==============

A collection of useful PowerShell scripts allowing you to retrieve arbitrary data from N-central agents, collect and push into Logstash for indexing and analysis in ElasticSearch.

<b>Requirements</b>

Logstash module found at https://github.com/m-dwyer/powershell-logstash

<b>How it Works</b>

After deploying NcentralUtil.psm1 to agent devices, after importing this module simply pipe the output of any PowerShell cmdlet to Upload-Object cmdlet.  For example:

`Get-ADUser -Filter * | Upload-Object -OutputName "ADUsers" -URI "https://myuser:mypass@some.server.com/folder"`

Either HTTPS (WebDAV) or FTP (with SSL - no certificate check!) can be used in the URI.

On a centralised server, periodically call the CSVtoLogstash.ps1 script from Task Scheduler or elsewhere, passing in the directory you wish to monitor, Report Manager SQL Server credentials and Logstash Server/Port.

The script expects CSV files of the format 1234567_MyOutput.csv, where 1234567 is the N-central ApplianceID, and MyOutput is an identifier for a script executed on the source agent (OutputName parameter of the Upload-Object cmdlet).  ApplianceIDs will be resolved to the Customer Name and Appliance Name.  The CSV will be converted to JSON and pushed to Logstash.  CustomerName, ApplianceName, estype and filetime fields are added.  estype is derived from the MyOutput string in each filename, and used for setting the type when indexing into ElasticSearch.  filetime is used as an alternate timestamp, taken from the CSV last write time.

<b>TODO</b>

Add XML serialization to allow retrieval of nested data / object graphs, such as with Export-Clixml and Import-Clixml.