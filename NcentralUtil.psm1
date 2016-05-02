function Get-AgentPropertyValue
{
    [CmdletBinding()]
    param([switch] $Force = $false, [string] $PropertyName, [string] $PropertyXPath)

    try
    {
        $propertyValue = $null

        if (-not $Force)
        {
            $keyProperties = Get-ItemProperty -ErrorAction SilentlyContinue "HKLM:\SOFTWARE\N-able Technologies"
            if ($keyProperties -ne $null)
            {
                $propertyValue = $keyProperties."$propertyName"
            }
        }

        if ($propertyValue -eq $null)
        {
            try
            {
                $appConfigFile = "${env:ProgramFiles(x86)}\N-able Technologies\Windows Agent\config\ApplianceConfig.xml"
                $appConfigXml = New-Object System.Xml.XmlDocument
                $fileStream = New-Object System.IO.Filestream $appConfigFile, 'Open', 'Read', 'ReadWrite'

                $appConfigXml.Load($fileStream)
                $propertyValue = $appConfigXml.SelectSingleNode("$PropertyXPath").Value
            }
            catch 
            {
                Write-Verbose $_.Exception.Message
            }
            finally
            {
                $fileStream.Dispose()
            }

            Set-ItemProperty "HKLM:\SOFTWARE\N-able Technologies" -Name "$PropertyName" -Value $propertyValue
        }

        return $propertyValue
    }
    catch
    {
        $computerSystem = Get-WmiObject -Class Win32_ComputerSystem
        return "$($computerSystem.Name)-$($computerSystem.Domain)"
    }
}

Function Get-ApplianceID
{
    [CmdletBinding()]
    param([switch] $Force = $false)

    Get-AgentPropertyValue -Force:$Force -PropertyName "ApplianceID" -PropertyXPath "/ApplianceConfig/ApplianceID/text()"
}

Function Get-CustomerID
{
    [CmdletBinding()]
    param([switch] $Force = $false)

    Get-AgentPropertyValue -Force:$Force -PropertyName "CustomerID" -PropertyXPath "/ApplianceConfig/CustomerID/text()"
}

Function Get-RemoteFileName
{
    [CmdletBinding()]
    param([string] $FileName)

    $applianceId = Get-ApplianceID
    return "$($applianceId)_$FileName"
}

Function Upload-File
{
    [CmdletBinding()]
    param(
    [Parameter(Mandatory=$true)]
    $LocalFile,
    [Parameter(Mandatory=$true)]
    [string] $URI,
    [Parameter(Mandatory=$true)]
    [string] $RemoteFile,
    [switch] $NoValidate = $false,
    [int] $RetryWait = 10,
    [int] $RetryCount = 5
    )

    if ($NoValidate)
    {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
    }

    $uriObj = New-Object System.Uri "$URI/$RemoteFile"
    $userInfo = $uriObj.UserInfo.Split(":")

    Write-Verbose "Reading local file [$LocalFile] bytes.."
    $fileContents = [System.IO.File]::ReadAllBytes($LocalFile)

    $attemptCount = 0
    $uploadSuccess = $false

    while ($attemptCount -lt $RetryCount -and $uploadSuccess -ne $true)
    {
        try 
        {
            $request = $null

            if ($uriObj.Scheme -eq 'https')
            {
                $request = [System.Net.HttpWebRequest]::Create($uriObj)
                $request.Method = [System.Net.WebRequestMethods+Http]::Put
                $auth = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$($userInfo[0]):$($userInfo[1])"));
                $request.Headers["Authorization"] = "Basic " + $auth
            }
            elseif ($uriObj.Scheme -eq 'ftp')
            {
                $request = [System.Net.FtpWebRequest]::Create($uriObj)
                $request.Method = [System.Net.WebRequestMethods+Ftp]::UploadFile
                $request.Credentials = New-Object System.Net.NetworkCredential($userInfo[0], $userInfo[1])
                $request.UseBinary = $true
                $request.UsePassive = $true
                $request.EnableSsl = $true
                $request.KeepAlive = $false
            }

            $request.ContentLength = $fileContents.Length
            $requestStream = $request.GetRequestStream()

            Write-Verbose "Writing local file [$localFile] to remote URI [$URI/$RemoteFile]"
            $requestStream.Write($fileContents, 0, $fileContents.Length)
            $requestStream.Close()
            $response = $request.GetResponse()
            Write-Verbose "Result: [$($response.StatusDescription -replace "`r`n", ' ')]"
            $response.Close()

            $uploadSuccess = $true
        }
        catch
        {
            if ($requestStream -ne $null) { $requestStream.Close() }
            if ($response -ne $null) { $response.Close() }
            $attemptCount++
            $exceptionMessage = "Upload failed $attemptCount attempts: $($_.Exception.Message)"
            if ($attemptCount -lt $RetryCount)
            {
                $exceptionMessage  += "`r`nTrying again after $RetryWait seconds.."
            }
            Write-Error $exceptionMessage

            Start-Sleep -Seconds $RetryWait
        }
    }

    Write-Verbose "$(if ($uploadSuccess) { "Finished" } else { "Failed" }) after $attemptCount attempts"
}

Function Upload-Object
{
    [CmdletBinding()]
    param(
    [Parameter(
        Mandatory=$true,
        Position=0,
        ValueFromPipeline=$true)
    ]
    [PSObject[]]$InputObject,
    [string] $OutputName,
    [ValidateSet("CSV", "XML")]
    [string] $OutputType = "CSV",
    [int] $Depth = 2,
    [Parameter(Mandatory=$true)]
    $URI
    )
        begin
        {
            $objects = @()
            $tempFileName = [System.IO.Path]::GetTempFileName()
        }

        process
        {
            foreach ($obj in $InputObject)
            {
                $objects += $obj
            }
        }

        end
        {
            if ($OutputType -eq 'CSV')
            {
                $objects | Export-Csv -Path $tempFileName
            }
            elseif ($OutputType -eq 'XML')
            {
                $objects | ConvertTo-XML -Depth $Depth -As String | Out-File -FilePath $tempFileName
            }

            Upload-File -Local $tempFileName -URI $URI -RemoteFile "$(Get-RemoteFileName -FileName $OutputName).$($OutputType.ToLower())" -NoValidate
        }
}
