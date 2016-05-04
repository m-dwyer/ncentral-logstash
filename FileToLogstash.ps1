[CmdletBinding()]
param([string] $SourceDirectory, [string] $SqlServer, [string] $SqlDatabase, [string] $SqlUser, [string] $SqlPassword, [string] $LogstashServer, [int] $LogstashPort)

function ConvertTo-JSONFriendlyPSObject
{
    param(
    [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
    [PSObject] $Object
    )

    $newProperties = @{}

    foreach ($property in $Object.PSObject.Properties)
    {
        $propertyVal = $property.Value
        if ($property.TypeNameOfValue -eq 'System.DateTime')
        {
            $propertyVal = $propertyVal.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss.fffffffK")
            $property.Value = $propertyVal
        }
        elseif ($propertyVal -ne $null)
        {
            $propertyVal | ConvertTo-JSONFriendlyPSObject
        }
    }
}

Import-Module Logstash

$sqlConnectionStr = "Server=$SqlServer;Database=$SqlDatabase;User ID=$SqlUser;Password=$SqlPassword;"
$sqlConnection = New-Object System.Data.SQLClient.SQLConnection
$sqlConnection.ConnectionString = $sqlConnectionStr

Write-Verbose "Checking $SourceDirectory for files.."

$items = Get-ChildItem -Path $SourceDirectory -Recurse -Include @("*.csv", "*.xml")

if ($items -eq $null)
{
    exit
}

if ($items.GetType().Name -ne 'Object[]')
{
    $items = @($items)
}

$appliances = @{}

$items | % {
    $item = $_

    $applianceId = -1
    if ($item -match '(\d+)_(.*(?=.csv|.xml))')
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

    $matchedFiles = $items -match "($resultApplianceId)_(.*(?=.csv|.xml))" | Select -ExpandProperty FullName
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
            $esType = [regex]::Match($applianceFile, '(\d+)_(.*(?=.csv|.xml))').Groups[2].Value
            $timestamp = (Get-Item $applianceFile).LastWriteTime.ToString("HH:mm:ss dd/MM/yyyy")

            $extension = [System.IO.Path]::GetExtension($applianceFile)
            if ($extension -eq '.csv')
            {
                Import-Csv -Path $applianceFile | % {
                    $esType = [regex]::Match($applianceFile, '(\d+)_(.*(?=.csv))').Groups[2].Value
                    $applianceObjects += $_ | Add-Member -PassThru -NotePropertyMembers @{"CustomerName" = $applianceAttributes.CustomerName; "ApplianceName" = $applianceAttributes.ApplianceName; "estype" = $esType; "filetime" = $timestamp }
                }
            }
            elseif ($extension -eq '.xml')
            {
                $applianceObjects = Import-CliXml $applianceFile

                $applianceObjects | % {
                    $applianceObject = $_

                    $applianceObject | ConvertTo-JSONFriendlyPSObject

                    $applianceObject | Add-Member -NotePropertyMembers @{
                        "CustomerName" = $applianceAttributes.CustomerName;
                        "ApplianceName" = $applianceAttributes.ApplianceName;
                        "estype" = $esType;
                        "filetime" = $timestamp
                    }
                }

                Write-Verbose "Done"
            }

            Write-Verbose "Pushing $($applianceObjects.Count) objects to Logstash.."

            $applianceObjects | PushTo-Logstash -Depth 10 -HostName $LogstashServer -Port $LogstashPort
            $totalPushCount += $applianceObjects.Count
            Remove-Item -Path $applianceFile
        }
        catch
        {
            Write-Error "An error occurred parsing $applianceFile to JSON and pushing to Logstash: $_.Exception.Message"
        }
    }
}

if (-not [System.Diagnostics.EventLog]::SourceExists(“FiletoLogstash"))
{
    [System.Diagnostics.EventLog]::CreateEventSource(“FiletoLogstash”, “Application”)
}

if ($totalPushCount -gt 0)
{
    Write-EventLog -LogName Application -Source "FiletoLogstash" -EntryType Information -EventId 1000 -Message "Pushed $totalPushCount objects from file to Logstash"
}

Write-Verbose "Done!"

