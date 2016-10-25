
$setupFolder = $PSScriptRoot
$logFilePath = Join-Path $setupFolder log.txt

function Write-Log {
    param (
        [string]$Level,
        [string]$Message
    )

    $timestamp = [System.DateTime]::Now.TimeOfDay.ToString()

    # FATAL, ERROR, WARNING, INFO, DEBUG, TRACE
    if (!$Level) {
        $Level = "INFO"    
    }
    $formattedMessage = "$timestamp - $($Level.PadLeft(8)) - $Message"

    switch ($level) {
        "FATAL"   { Write-Host $formattedMessage -ForegroundColor White -BackgroundColor Red }
        "ERROR"   { Write-Host $formattedMessage -ForegroundColor White -BackgroundColor Red }
        "WARNING" { Write-Host $formattedMessage -ForegroundColor Yellow }
        "INFO"    { Write-Host $formattedMessage -ForegroundColor White }
        "DEBUG"   { Write-Host $formattedMessage -ForegroundColor Cyan }
        "TRACE"   { Write-Host $formattedMessage -ForegroundColor Gray }
        default   { Write-Host $formattedMessage -ForegroundColor White }
    }

    if ($logFilePath) {
        Add-content $logFilePath -value $formattedMessage
    }
}

function Convert-PSObjectToHashtable {
    param (
        [Parameter(  
             Position = 0,   
             ValueFromPipeline = $true,  
             ValueFromPipelineByPropertyName = $true  
         )]
        [object]$InputObject
    )

    if (-not $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $output = @(
            foreach ($item in $InputObject) {
                Convert-PSObjectToHashtable $item
            }
        )

        Write-Output -NoEnumerate $output
    }
    elseif ($InputObject -is [psobject]) {
        $output = @{}
        $InputObject | Get-Member -MemberType *Property | % { 
            $output.($_.name) = Convert-PSObjectToHashtable $InputObject.($_.name)
        } 
        $output
    }
    else {
        $InputObject
    }
}

function Get-AvailableDriveLetter {
    param(
       [parameter(Mandatory=$False)]
       [Switch]
       $ReturnFirstLetterOnly
   )
 
   $volumeList = Get-Volume
   # Get all available drive letters, and store in a temporary variable.
   $usedDriveLetters = @(Get-Volume | % { "$([char]$_.DriveLetter)"}) + @(Get-WmiObject -Class Win32_MappedLogicalDisk| %{$([char]$_.DeviceID.Trim(':'))})
   $tempDriveLetters = @(Compare-Object -DifferenceObject $usedDriveLetters -ReferenceObject $( 67..90 | % { "$([char]$_)" } ) | ? { $_.SideIndicator -eq '<=' } | % { $_.InputObject })
 
   # For completeness, sort the output alphabetically
   $availableDriveLetter = ($tempDriveLetters | Sort-Object)
   if ($ReturnFirstLetterOnly -eq $true)
   {
      $tempDriveLetters[0]
   }
   else
   {
      $tempDriveLetters
   }
}

try {
    Write-Log "INFO" "Starting setup-complete script in '$setupFolder'"
    Write-Log "INFO" "Running as '$($env:USERNAME)'"

    #######################################
    # Initialize PowerShell environment
    #######################################
    Write-Log "INFO" "Setting execution policy"
    Set-ExecutionPolicy Unrestricted -Force
    Write-Log "INFO" "Finished setting execution policy"

    #######################################
    # Enable PS-Remoting
    #######################################
    Write-Log "INFO" "Enabling PowerShell remoting"
    Enable-PSRemoting -SkipNetworkProfileCheck -Force -Confirm:$false
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Service\' -Name 'allow_unencrypted' -Value 0x1
    Set-Item WSMan:\localhost\Client\TrustedHosts * -Force
    Set-Item WSMan:\localhost\Client\AllowUnencrypted $true -Force
    Restart-Service winrm
    Write-Log "INFO" "Finished enabling PowerShell remoting"

    #######################################
    # Enable CredSSP
    #######################################
    Write-Log "INFO" "Enabling CredSSP authentication"
    Enable-WSManCredSSP -Role Server -Force | Out-Null
    Enable-WSManCredSSP -Role Client -DelegateComputer * -Force | Out-Null
    Write-Log "INFO" "Finished enabling CredSSP authentication"

    #######################################
    # Load configuration
    #######################################
    Write-Log "INFO" "Loading configuration"
    $configurationFilePath = Join-Path -Path $setupFolder -ChildPath configuration.json
    if (Test-Path -Path $configurationFilePath -PathType Leaf) {
        $configuration = Get-Content -Path $configurationFilePath -Raw | ConvertFrom-Json
        Write-Log "INFO" "Finished loading configuration"
    }
    else {
        Write-Log "INFO" "Finished loading configuration"
    }

    #######################################
    # Extra disk
    #######################################
    Write-Log "INFO" "Checking offline disk(s)"
	$offlineDisks = Get-Disk | Where { $_.OperationalStatus -eq "Offline" }
	if ($offlineDisks) {
	    Write-Log "INFO" "Processing $($offlineDisks.Length) disks"
		foreach ($offlineDisk in $offlineDisks) {
			Write-Log "INFO" "Bringing disk '$($offlineDisk.Model)' ($($offlineDisk.Size)) online"
			Set-Disk -Number $offlineDisk.Number -IsOffline $false
			Write-Log "INFO" "Disk is online"

			if (!(Get-Partition -DiskNumber $offlineDisk.Number -ErrorAction SilentlyContinue)) {
				Write-Log "INFO" "Creating partition"
                # TODO: use driveletter from configuration
                $driveLetter = Get-AvailableDriveLetter -ReturnFirstLetterOnly
				$offlineDisk | Initialize-Disk -PartitionStyle GPT
				$offlineDisk | New-Partition -UseMaximumSize -DriveLetter $driveLetter
				$offlineDisk | Get-Partition | Format-Volume -FileSystem NTFS -NewFileSystemLabel Data -Confirm:$false
				Write-Log "INFO" "Partition created ($($driveLetter):)"
			}
 		}
	}
	else {
		Write-Log "INFO" "No offline disk(s)"
	}

    #######################################
    # Network adapters
    #######################################
    Write-Log "INFO" "Renaming network adapters"
    foreach ($netAdapter in Get-NetAdapter) {
        Write-Log "INFO" "Renaming network adapter '$($netAdapter.Name)'"
        $networkAdapterName = (Get-NetAdapterAdvancedProperty -Name $netAdapter.Name -DisplayName 'Hyper-V Network Adapter Name').DisplayValue
        if ($netAdapter.Name -ne $networkAdapterName) {
            Write-Log "INFO" "Renaming network adapter '$($netAdapter.Name)' to '$networkAdapterName'"
            Rename-NetAdapter -Name $netAdapter.Name -NewName $networkAdapterName
            Write-Log "INFO" "Finished renaming network adapter '$($netAdapter.Name)' to '$networkAdapterName'"
        }
        else {
            Write-Log "INFO" "Skipping renaming network adapter '$($netAdapter.Name)'"
        }
    }
    Write-Log "INFO" "Finished renaming network adapters"

    #######################################
    # Setup-script
    #######################################
    $setupScriptPath = Join-Path -Path $setupFolder -ChildPath 'SetupScript.ps1'
    if (Test-Path -Path $setupScriptPath -PathType Leaf) {
        Write-Log "INFO" "Executing setup-script at '$setupScriptPath'"
        . $setupScriptPath
        Write-Log "INFO" "Finished executing setup-script at '$setupScriptPath'"
    }
    else {
        Write-Log "INFO" "Setup-script at '$setupScriptPath' not found; execution skipped"
    }

    Write-Log "INFO" "Finished setup-complete script"
}
catch {
    Write-Log "ERROR" $_
}
