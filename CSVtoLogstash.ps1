[CmdletBinding()]
param([string] $CsvDirectory, [string] $SqlServer, [string] $SqlDatabase, [string] $SqlUser, [string] $SqlPassword, [string] $LogstashServer, [int] $LogstashPort)

Import-Module Logstash

$sqlConnectionStr = "Server=$SqlServer;Database=$SqlDatabase;User ID=$SqlUser;Password=$SqlPassword;"
$sqlConnection = New-Object System.Data.SQLClient.SQLConnection
$sqlConnection.ConnectionString = $sqlConnectionStr

Write-Verbose "Checking $CsvDirectory for CSV files.."
$csvItems = Get-ChildItem -Path $CsvDirectory -Filter "*.csv"

if ($csvItems -eq $null)
{
    exit
}

$appliances = @{}

$csvItems | % {
    $csvItem = $_

    $applianceId = -1
    if ($csvItem -match '(\d+)_(.*(?=.csv))')
    {
        $applianceId = $Matches[1]
    }
    else
    {
        continue
    }

    $applianceInfo = New-Object PSObject -Property @{
        "CustomerName" = "NA"
        "ApplianceName" = "NA"
        "ApplianceFiles" = @()
    }

    if (-not ($appliances.ContainsKey([int] $applianceId)))
    {
        $appliances.Add([int] $applianceId, $applianceInfo)
    }
}

$sql =  "SELECT app.applianceid, cust.customername, app.appliancename "
$sql += "FROM dbo.appliance app "
$sql += "INNER JOIN dbo.customer cust ON app.customerid = cust.customerid "
$sql += "WHERE app.applianceid IN ($($appliances.Keys -Join ", "))"

$sqlConnection.Open()

$sqlCommand = New-Object System.Data.SqlClient.SqlCommand
$sqlCommand.Connection = $sqlConnection
$sqlCommand.CommandText = $sql
$sqlCommand.CommandTimeout = 300

Write-Host "Querying ODS to resolve Appliance IDs to Customer and Appliance Names..."
$result = $sqlCommand.ExecuteReader()

Write-Host "Processing results..."
$result | % {
    $resultApplianceId = $result.GetInt32(0)
    $resultCustomerName = $result.GetString(1)
    $resultApplianceName = $result.GetString(2)

    $applianceAttributes = $appliances[$resultApplianceId]
    $applianceAttributes.ApplianceName = $resultApplianceName
    $applianceAttributes.CustomerName = $resultCustomerName

    $matchedFiles = $csvItems -match "($resultApplianceId)_(.*(?=.csv))" | Select -ExpandProperty FullName
    $applianceAttributes.ApplianceFiles += $matchedFiles
}

$totalPushCount = 0

$appliances.GetEnumerator() | % {
    $appliance = $_

    $applianceAttributes = $appliance.Value

    $applianceAttributes.ApplianceFiles | % {
        $applianceFile = $_

        $applianceObjects = @()

        Write-Verbose "Processing $applianceFile"
        try
        {
            Import-Csv -Path $applianceFile | % {
                $esType = [regex]::Match($applianceFile, '(\d+)_(.*(?=.csv))').Groups[2].Value
                $timestamp = (Get-Item $applianceFile).LastWriteTime.ToString("HH:mm:ss dd/MM/yyyy")
                $applianceObjects += $_ | Add-Member -PassThru -NotePropertyMembers @{"CustomerName" = $applianceAttributes.CustomerName; "ApplianceName" = $applianceAttributes.ApplianceName; "estype" = $esType; "filetime" = $timestamp }
            }

            Write-Verbose "Pushing $($applianceObjects.Count) objects to Logstash.."

            $applianceObjects | PushTo-Logstash -HostName $LogstashServer -Port $LogstashPort
            $totalPushCount += $applianceObjects.Count
            Remove-Item -Path $applianceFile
        }
        catch
        {
            Write-Error "An error occurred parsing CSV to JSON and pushing to Logstash: $_.Exception.Message"
        }
    }
}

if (-not [System.Diagnostics.EventLog]::SourceExists(“CSVtoLogstash"))
{
    [System.Diagnostics.EventLog]::CreateEventSource(“CSVtoLogstash”, “Application”)
}

if ($totalPushCount -gt 0)
{
    Write-EventLog -LogName Application -Source "CSVtoLogstash" -EntryType Information -EventId 1000 -Message "Pushed $totalPushCount objects from CSV to Logstash"
}

Write-Verbose "Done!"