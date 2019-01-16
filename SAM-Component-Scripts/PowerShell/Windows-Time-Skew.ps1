# Modification of SAM Template found here: https://thwack.solarwinds.com/docs/DOC-147721
# This version varies from the original in the following ways:
#   - adds 'Statistic.Message' property for queries
#   - adds multiple try/catch blocks to account for common failure scenarios
#   - attempts fallback of 'Get-WmiObject' queries that generated exception when run against a local computer by running without 'Credential' parameter
#   - returns a null statistic, unique exit code, and unique error message for each failure scenario to aid in troubleshooting failures
# Note: exit codes are greater than 3 so that component is marked with status 'Unknown' rather than 'Down'

# This script attempts to discover the time skew of a remote Windows server to an accuracy of 1 second.
# The NTP server name or IP should be entered in to the Script Arguments in SolarWinds.

# First, the NTP server is queried from the SolarWinds poller to determine the time skew of the poller.
# Second, if that is successful then the remote Windows server is polled via WMI to retrieve the server's time in UTC.
# Third, the local poller's time is compared to the remote server's time to find the time skew between the two servers.
# Fourth, the NTP skew is subtracted from the server skew to get the skew between the remote server and the NTP server
# Fifth, the skew is converted to an INTEGER so the returned result accuracy is 1 second.
# The limitation of 1 second is because while the the Win32_UTCTime object returns a Milliseconds field, it is unused (brilliant!).

# Get the NTP server from the Script Arguments field
$ntpServer = $args[0]

$Error.Clear()

# Query the NTP server and store the output as a string
Try {
    $ntpQuery  =  Invoke-Expression "w32tm /monitor /computers:$ntpServer" | Out-String
}
Catch {
    Write-Host "Statistic: $NULL"
    Write-Host "Message: Error querying NTP server '$ntpServer' with 'w32tm'"
    exit 10
}

# Use REGEX to get the number of seconds from the output of the w32tm command.  This can leave a + symbol in front of the number which goes away with the arithmetic later
$findSkew = [regex]"(?:NTP\: )(?<Value>/?[^s]+)"

# Check to see if there is a value picked up by the REGEX, otherwise exit with an error.
If ($ntpQuery -notmatch $findSkew) {
    Write-Host "Statistic: $NULL"
    Write-Host "Message: Result of 'w32tm' query does not match REGEX format."
    exit 20
}
Else {
    # Store the time skew value in a friendlier name
    $ntpToSolarSkew = $Matches['Value']
    
    Try {
        # Retrieve the remote servers time over WMI via Node's IP
        $remoteServerTime = Get-WmiObject Win32_UTCTime -ComputerName '${IP}' -Credential '${CREDENTIAL}' -ErrorAction Stop
        $QueryType = "IP '${IP}'"
    }
    Catch {
        # Check whether Get-WmiObject exception was related to local credentials
        If ($($_.Exception.Message) -like "*User credentials cannot be used for local connections*") {
            Try {
                # Rerun query using ${Node.DNS} instead of ${IP} and without using 'Credential' parameter
                $remoteServerTime = Get-WmiObject Win32_UTCTime -ComputerName '${Node.DNS}' -ErrorAction Stop
                $QueryType = "DNS '$('${Node.DNS}'.ToLower())'"
            }
            Catch {
                # Write null statistic and error message for non-credentialed 'Get-WmiObject' query against DNS
                Write-Host "Statistic: $NULL"
                Write-Host "Message: Exception running Get-WmiObject against DNS '${Node.DNS}' - $($_.Exception.Message)"
                exit 30
            }
        }
        Else {
            # Write null statistic and error message for credentialed 'Get-WmiObject' query against IP
            Write-Host "Statistic: $NULL"
            Write-Host "Message: Exception running Get-WmiObject against IP '${IP}' - $($_.Exception.Message)"
            exit 40
        }
    }
    
    Try {
        # Get the local poller server's time in UTC
        $localTimeRaw = Get-Date -ErrorAction Stop
        $localTimeUTC = $localTimeRaw.ToUniversalTime()
    }
    Catch {
        # Write null statistic and error message for credentialed 'Get-WmiObject' query against IP
        Write-Host "Statistic: $NULL"
        Write-Host "Message: Exception determining poller current UTC time - $($_.Exception.Message)"
        exit 50
    }
    
    Try {
        # Compare the remote server and local poller's time to get the time skew between the two
        $remoteTimeFormatted = Get-Date -Year $remoteServerTime.Year -Month $remoteServerTime.Month -Day $remoteServerTime.Day -Hour $remoteServerTime.Hour -Minute $remoteServerTime.Minute -Second $remoteServerTime.Second
        $remoteToSolarSkew = New-TimeSpan -Start $localTimeUTC -End $remoteTimeFormatted
    }
    Catch {
        Write-Host "Statistic: $NULL"
        Write-Host "Message: Exception getting time span between poller and node - $($_.Exception.Message)"
        exit 60
    }
            
        
    # Check if a valid skew is found, otherwise throw an error.
    If ($remoteToSolarSkew) {
        # The NTP skew is subtracted from the server skew to get the skew between the remote server and the NTP server
        $Skew = $remoteToSolarSkew.TotalSeconds - $ntpToSolarSkew
            
        # The skew is converted to an INTEGER so that the returned result is only 1 second. Also get the absolute value so that thresholds work in SolarWinds
        $Skew = [math]::abs([int]$Skew)
            
        # Write out the value in a way that it is picked up by SolarWinds and then exit as successful.
        Write-Host "Statistic: $Skew"
        Write-Host "Message: Queried $QueryType and determined skew: $Skew"
        exit 0
    }
    Else {
        Write-Host "Statistic: $NULL"
        Write-Host "Message: Null result while comparing poller and node times"
        exit 70
    }
}
