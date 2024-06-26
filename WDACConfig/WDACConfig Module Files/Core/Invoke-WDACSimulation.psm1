Function Invoke-WDACSimulation {
    [CmdletBinding()]
    [OutputType([System.Object[]], [System.Boolean])]
    Param(
        [Alias('X')]
        [ValidateScript({ Test-CiPolicy -XmlFile $_ })]
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$XmlFilePath,

        [Alias('D')]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType 'Container' }, ErrorMessage = 'The path you selected is not a valid folder path.')]
        [Parameter(Mandatory = $false)][System.IO.DirectoryInfo]$FolderPath,

        [Alias('F')]
        [ValidateScript({
                # Ensure the selected path is a file path
                if (Test-Path -LiteralPath $_ -PathType 'Leaf') {
                    # Ensure the selected file has a supported extension
                    [System.IO.FileInfo]$SelectedFile = Get-ChildItem -File -LiteralPath $_ -Include '*.sys', '*.exe', '*.com', '*.dll', '*.rll', '*.ocx', '*.msp', '*.mst', '*.msi', '*.js', '*.vbs', '*.ps1', '*.appx', '*.bin', '*.bat', '*.hxs', '*.mui', '*.lex', '*.mof'
                    # If the selected file has a supported extension, return $true
                    if ($SelectedFile) {
                        $true
                    }
                    else {
                        Throw 'The selected file is not supported by the WDAC engine.'
                    }
                }
                else { $false }
            }, ErrorMessage = 'The path you selected is not a file path.')]
        [Parameter(Mandatory = $false)][System.IO.FileInfo]$FilePath,

        [Alias('B')]
        [Parameter(Mandatory = $false)][System.Management.Automation.SwitchParameter]$BooleanOutput,

        [Alias('L')]
        [Parameter(Mandatory = $false)][System.Management.Automation.SwitchParameter]$Log,

        [Alias('C')]
        [Parameter(Mandatory = $false)][System.Management.Automation.SwitchParameter]$CSVOutput,

        [Alias('S')]
        [Parameter(Mandatory = $false)][System.Management.Automation.SwitchParameter]$SkipVersionCheck
    )

    begin {
        # Detecting if Verbose switch is used
        $PSBoundParameters.Verbose.IsPresent ? ([System.Boolean]$Verbose = $true) : ([System.Boolean]$Verbose = $false) | Out-Null

        # Importing the $PSDefaultParameterValues to the current session, prior to everything else
        . "$ModuleRootPath\CoreExt\PSDefaultParameterValues.ps1"

        Write-Verbose -Message 'Importing the required sub-modules'
        Import-Module -FullyQualifiedName "$ModuleRootPath\Shared\Update-Self.psm1" -Force
        Import-Module -FullyQualifiedName "$ModuleRootPath\Shared\Write-ColorfulText.psm1" -Force
        Import-Module -FullyQualifiedName "$ModuleRootPath\WDACSimulation\Compare-SignerAndCertificate.psm1" -Force
        Import-Module -FullyQualifiedName "$ModuleRootPath\WDACSimulation\Get-FileRuleOutput.psm1" -Force

        # if -SkipVersionCheck wasn't passed, run the updater
        if (-NOT $SkipVersionCheck) { Update-Self -InvocationStatement $MyInvocation.Statement }

        # Start the transcript if the -Log switch is used and create a function to stop the transcript and the stopwatch at the end
        if ($Log) {
            Start-Transcript -IncludeInvocationHeader -LiteralPath (Join-Path -Path $UserConfigDir -ChildPath "WDAC Simulation Log $(Get-Date -Format "MM-dd-yyyy 'at' HH-mm-ss").txt")

            # Create a new stopwatch object to measure the execution time
            Write-Verbose -Message 'Starting the stopwatch...'
            [System.Diagnostics.Stopwatch]$StopWatch = [Diagnostics.Stopwatch]::StartNew()
            Function Stop-Log {
                <#
                .SYNOPSIS
                    Stops the stopwatch and the transcription when the -Log switch is used with the Invoke-WDACSimulation cmdlet
                .Inputs
                    None
                .Outputs
                    System.Void
                #>
                [CmdletBinding()]
                [OutputType([System.Void])]
                param()

                Write-Verbose -Message 'Stopping the stopwatch'
                $StopWatch.Stop()
                Write-Verbose -Message "WDAC Simulation for $TotalSubSteps files completed in $($StopWatch.Elapsed.Hours) Hours - $($StopWatch.Elapsed.Minutes) Minutes - $($StopWatch.Elapsed.Seconds) Seconds - $($StopWatch.Elapsed.Milliseconds) Milliseconds - $($StopWatch.Elapsed.Microseconds) Microseconds - $($StopWatch.Elapsed.Nanoseconds) Nanoseconds"

                Write-Verbose -Message 'Stopping the transcription'
                Stop-Transcript
            }
        }

        # The total number of the main steps for the progress bar to render
        [System.Int16]$TotalSteps = 4
        [System.Int16]$CurrentStep = 0

        # Make sure either -FolderPath or -FilePath is specified, but not both
        if (-not ($PSBoundParameters.ContainsKey('FolderPath') -xor $PSBoundParameters.ContainsKey('FilePath'))) {
            # Write an error message
            Write-Error -Message 'You must specify either -FolderPath or -FilePath, but not both.' -Category InvalidArgument
        }

        # Check if the supplied XML file contains Allow all rule
        [System.Boolean]$ShouldExit = $false

        if ((Get-Content -LiteralPath $XmlFilePath -Raw) -match '<Allow ID="ID_ALLOW_.*" FriendlyName=".*" FileName="\*".*/>') {
            Write-Verbose -Message 'The supplied XML file contains a rule that allows all files.' -Verbose

            # Set a flag to exit the subsequent blocks
            $ShouldExit = $true

            # Exit the Begin block
            Return
        }
    }

    process {
        # Exit the Process block
        if ($ShouldExit) { Return }

        # Store the PSCustomObjects that contain file paths and SpecificFileNameLevel options of valid Allowed Signed files - FilePublisher level
        [System.Object[]]$SignedFile_FilePublisher_Objects = @()

        # Store the file paths of valid Allowed Signed files - Publisher level
        [System.IO.FileInfo[]]$SignedFile_Publisher_FilePaths = @()

        # Store the file paths of valid Allowed Signed files - SignedVersion level
        [System.IO.FileInfo[]]$SignedFile_SignedVersion_FilePaths = @()

        # Store the file paths of valid Allowed Signed files - PcaCertificate and RootCertificate levels
        [System.IO.FileInfo[]]$SignedFile_PcaCertificateAndRootCertificate_FilePaths = @()

        # Store the file paths of valid Allowed Signed files - LeafCertificate level
        [System.IO.FileInfo[]]$SignedFile_LeafCertificate_FilePaths = @()

        # Store the paths of files allowed by Hash
        [System.IO.FileInfo[]]$AllowedByHashFilePaths = @()

        # Store the paths of Signed files with HashMismatch Status
        [System.IO.FileInfo[]]$SignedHashMismatchFilePaths = @()

        # Store the PSCustomObjects that contain file paths of Signed files with a status that doesn't fall into any other category and their exact signature status
        [System.Object[]]$SignedButUnknownObjects = @()

        # Store the paths of Signed files with EKU mismatch
        [System.IO.FileInfo[]]$SignedButEKUMismatch = @()

        # Store the paths of the signed files that are inaccessible (Kernel-Protected files, Microsoft Defender files etc.)
        [System.IO.FileInfo[]]$InAccessibleFilePaths = @()

        # Store the paths of Signed files that are not allowed
        [System.IO.FileInfo[]]$SignedButNotAllowed = @()

        # Store the paths of Unsigned files that are not allowed by hash
        [System.IO.FileInfo[]]$UnsignedNotAllowedFilePaths = @()

        # Store the final object of all of the results
        [System.Object[]]$MegaOutputObject = @()

        # Hash Sha256 values of all the file rules based on hash in the supplied xml policy file
        Write-Verbose -Message 'Getting the Sha256 Hash values of all the file rules based on hash in the supplied xml policy file'

        $CurrentStep++
        Write-Progress -Id 0 -Activity 'Getting the Sha256 Hash values from the XML file' -Status "Step $CurrentStep/$TotalSteps" -PercentComplete ($CurrentStep / $TotalSteps * 100)

        [System.String[]]$SHA256HashesFromXML = (Get-FileRuleOutput -xmlPath $XmlFilePath).hashvalue

        # Get all of the file paths of the files that WDAC supports, from the user provided directory
        Write-Verbose -Message 'Getting all of the file paths of the files that WDAC supports, from the user provided directory'

        $CurrentStep++
        Write-Progress -Id 0 -Activity "Getting the supported files' paths" -Status "Step $CurrentStep/$TotalSteps" -PercentComplete ($CurrentStep / $TotalSteps * 100)

        if ($FilePath) {
            [System.IO.FileInfo]$CollectedFiles = Get-ChildItem -File -LiteralPath $FilePath
        }
        else {
            [System.IO.FileInfo[]]$CollectedFiles = (Get-ChildItem -Recurse -LiteralPath $FolderPath -File -Include '*.sys', '*.exe', '*.com', '*.dll', '*.rll', '*.ocx', '*.msp', '*.mst', '*.msi', '*.js', '*.vbs', '*.ps1', '*.appx', '*.bin', '*.bat', '*.hxs', '*.mui', '*.lex', '*.mof').FullName
        }

        # Make sure the selected directory contains files with the supported extensions
        if (!$CollectedFiles) { Throw 'There are no files in the selected directory that are supported by the WDAC engine.' }

        try {

            #Region Cyan/Violet Progress Bar

            # Backing up PS Formatting Styles
            [System.Collections.Hashtable]$OriginalStyle = @{}
            $PSStyle.Progress | Get-Member -MemberType Property | ForEach-Object -Process {
                $OriginalStyle[$_.Name] = $PSStyle.Progress.$($_.Name)
            }

            # Define a global variable to store the current color index
            [System.UInt16]$Global:ColorIndex = 0

            # Create a timer object that fires every 3 seconds
            [System.Timers.Timer]$RainbowTimer = New-Object System.Timers.Timer
            $RainbowTimer.Interval = 3000 # milliseconds
            $RainbowTimer.AutoReset = $true # repeat until stopped

            # Register an event handler that changes Write-Progress' style every time the timer elapses
            [System.Management.Automation.PSEventJob]$EventHandler = Register-ObjectEvent -InputObject $RainbowTimer -EventName Elapsed -Action {

                # An array of colors
                [System.Drawing.Color[]]$Colors = @(
                    [System.Drawing.Color]::Cyan
                    [System.Drawing.Color]::Violet
                )

                $Global:ColorIndex++
                if ($Global:ColorIndex -ge $Colors.Length) {
                    $Global:ColorIndex = 0
                }

                # Get the current color from the array
                [System.Drawing.Color]$CurrentColor = $Colors[$Global:ColorIndex]
                # Set the progress bar style to use the current color
                $PSStyle.Progress.Style = "$($PSStyle.Foreground.FromRGB($CurrentColor.R, $CurrentColor.G, $CurrentColor.B))"
            }

            # Start the timer
            $RainbowTimer.Start()

            #Endregion Cyan/Violet Progress Bar

            # Loop through each file
            Write-Verbose -Message 'Looping through each supported file'

            $CurrentStep++
            Write-Progress -Id 0 -Activity 'Looping through each supported file' -Status "Step $CurrentStep/$TotalSteps" -PercentComplete ($CurrentStep / $TotalSteps * 100)

            # The total number of the sub steps for the progress bar to render
            [System.UInt64]$TotalSubSteps = $CollectedFiles.Count
            [System.UInt64]$CurrentSubStep = 0

            foreach ($CurrentFilePath in $CollectedFiles) {

                Write-Verbose -Message "Processing file: $CurrentFilePath"

                $CurrentSubStep++
                Write-Progress -Id 1 -ParentId 0 -Activity "Processing file $CurrentSubStep/$TotalSubSteps" -Status "$CurrentFilePath" -PercentComplete ($CurrentSubStep / $TotalSubSteps * 100)

                # Check see if the file's hash exists in the XML file regardless of whether it's signed or not
                # This is because WDAC policies sometimes have hash rules for signed files too
                # So here we prioritize being authorized by file hash over being authorized by Signature

                <#
                try {
                    Write-Verbose -Message 'Using Get-AppLockerFileInformation to retrieve the hashes of the file'
                    # Since Get-AppLockerFileInformation doesn't support special characters such as [ and ], and it doesn't have -LiteralPath parameter, we need to escape them ourselves
                    [System.String]$CurrentFilePathHash = (Get-AppLockerFileInformation -Path $($CurrentFilePath -match '\[|\]' ? ($CurrentFilePath -replace '(\[|\])', '`$1') : $CurrentFilePath) -ErrorAction Stop).hash -replace 'SHA256 0x', ''
                }
                catch {
                    Write-Verbose -Message 'Get-AppLockerFileInformation failed because the file is non-conformant, getting the flat file hash instead'
                    [System.String]$CurrentFilePathHash = (Get-CiFileHashes -FilePath $CurrentFilePath -SkipVersionCheck).SHA256Authenticode
                }
                #>

                Write-Verbose -Message 'Calculating the file hashes'
                # Get-CiFileHashes is faster, natively supports -LiteralPath for special characters in file path, and also supports non-conformant files by automatically getting their flat hashes
                [System.String]$CurrentFilePathHash = (Get-CiFileHashes -FilePath $CurrentFilePath -SkipVersionCheck).SHA256Authenticode

                # if the file's hash exists in the XML file then add the file's path to the allowed files and do not check anymore that whether the file is signed or not
                if ($CurrentFilePathHash -in $SHA256HashesFromXML) {
                    Write-Verbose -Message 'Hash of the file exists in the supplied XML file'

                    $AllowedByHashFilePaths += $CurrentFilePath
                }

                # If the file's extension is not supported by Authenticode and it wasn't allowed by file hash then it's not allowed and no reason to check its signature
                elseif ($CurrentFilePath.Extension -in @('.ocx', '.bat')) {
                    Write-Verbose -Message 'The file is not signed and is not allowed by hash'

                    $UnsignedNotAllowedFilePaths += $CurrentFilePath
                }

                # If the file's hash does not exist in the supplied XML file, then check its signature
                else {

                    # Get the status of file's signature
                    :MainSwitchLabel switch (Get-AuthenticodeSignature -LiteralPath $CurrentFilePath) {

                        # If the file is signed and valid
                        { $_.Status -eq 'valid' } {

                            try {
                                # Use the Compare-SignerAndCertificate function to process it
                                $ComparisonResult = Compare-SignerAndCertificate -XmlFilePath $XmlFilePath -SignedFilePath $CurrentFilePath
                            }
                            catch [ExceptionFailedToGetCertificateCollection] {
                                # If the file's certificate collections could not be fetched due to lack of necessary permissions, place it in a different array of file path
                                $InAccessibleFilePaths += $CurrentFilePath

                                break MainSwitchLabel
                            }
                            # If there is no comparison result then the file is not allowed by the policy
                            if (([System.String]::IsNullOrWhiteSpace($ComparisonResult))) {

                                Write-Verbose -Message 'The file is signed and valid, but not allowed by the policy'

                                $SignedButNotAllowed += $CurrentFilePath
                            }

                            # If the file's signer requires the file to have specific EKU(s) but the file doesn't meet it
                            elseif ($ComparisonResult.HasEKU -and (-NOT $ComparisonResult.EKUsMatch)) {
                                Write-Verbose -Message 'The file is signed and valid, but does not meet the EKU requirements'

                                $SignedButEKUMismatch += $CurrentFilePath
                            }

                            # Continue only if the file is authorized by a signer and doesn't have EKU mismatch
                            else {

                                :Level2SwitchLabel switch ($ComparisonResult.MatchCriteria) {
                                    'FilePublisher' {
                                        Write-Verbose -Message 'The file is signed and valid, and allowed by the policy using FilePublisher level'

                                        $SignedFile_FilePublisher_Objects += [PSCustomObject]@{
                                            FilePath              = [System.IO.FileInfo]$CurrentFilePath
                                            SpecificFileNameLevel = [System.String]$ComparisonResult.SpecificFileNameLevelMatchCriteria
                                        }

                                        break Level2SwitchLabel
                                    }

                                    'Publisher' {
                                        Write-Verbose -Message 'The file is signed and valid, and allowed by the policy using Publisher level'

                                        $SignedFile_Publisher_FilePaths += $CurrentFilePath

                                        break Level2SwitchLabel
                                    }

                                    'SignedVersion' {
                                        Write-Verbose -Message 'The file is signed and valid, and allowed by the policy using SignedVersion level'

                                        $SignedFile_SignedVersion_FilePaths += $CurrentFilePath

                                        break Level2SwitchLabel
                                    }

                                    'PcaCertificate/RootCertificate' {
                                        Write-Verbose -Message 'The file is signed and valid, and allowed by the policy using PcaCertificate/RootCertificate levels'

                                        $SignedFile_PcaCertificateAndRootCertificate_FilePaths += $CurrentFilePath

                                        break Level2SwitchLabel
                                    }
                                    'LeafCertificate' {
                                        Write-Verbose -Message 'The file is signed and valid, and allowed by the policy using LeafCertificate level'

                                        $SignedFile_LeafCertificate_FilePaths += $CurrentFilePath

                                        break Level2SwitchLabel
                                    }
                                }
                            }

                            break MainSwitchLabel
                        }

                        # If the file is signed but is tampered
                        { $_.Status -eq 'HashMismatch' } {
                            Write-Warning -Message "The file: $CurrentFilePath has hash mismatch, it is most likely tampered."

                            $SignedHashMismatchFilePaths += $CurrentFilePath

                            break MainSwitchLabel
                        }

                        # If the file is not signed
                        { $_.Status -eq 'NotSigned' } {
                            Write-Verbose -Message 'The file is not signed and is not allowed by hash'

                            $UnsignedNotAllowedFilePaths += $CurrentFilePath

                            break MainSwitchLabel
                        }

                        # If the file is signed but has unknown signature status
                        default {
                            Write-Verbose -Message 'The file has unknown signature status'

                            # Store the filepath and reason for the unknown status
                            $SignedButUnknownObjects += [PSCustomObject]@{
                                FilePath      = [System.IO.FileInfo]$CurrentFilePath
                                FailureReason = $_.StatusMessage
                            }

                            break MainSwitchLabel
                        }
                    }
                }
            }
        }
        catch {
            # Complete the main progress bar because there was an error
            Write-Progress -Id 0 -Activity 'WDAC Simulation interrupted.' -Completed

            # If the -Log switch is used, then stop the stopwatch and the transcription
            if ($Log) { Stop-Log }

            # Throw whatever error that was encountered
            throw $_
        }
        finally {
            # Complete the nested progress bar whether there was an error or not
            Write-Progress -Id 1 -Activity 'All of the files have been processed.' -Completed

            # Stop the timer for progress bar color
            $RainbowTimer.Stop()

            # Unregister the event handler for progress bar color
            Unregister-Event -SourceIdentifier $EventHandler.Name -Force

            # Restore PS Formatting Styles for progress bar
            $OriginalStyle.Keys | ForEach-Object -Process {
                $PSStyle.Progress.$_ = $OriginalStyle[$_]
            }
        }

        $CurrentStep++
        Write-Progress -Id 0 -Activity 'Preparing the output' -Status "Step $CurrentStep/$TotalSteps" -PercentComplete ($CurrentStep / $TotalSteps * 100)

        if ($AllowedByHashFilePaths) {
            Write-Verbose -Message 'Looping through the array of files allowed by hash'
            Write-Verbose -Message "$($AllowedByHashFilePaths.count) File(s) are allowed by their Hashes." -Verbose
            foreach ($Path in $AllowedByHashFilePaths) {
                # Create a hash table with the file path and source
                [System.Collections.Hashtable]$Object = @{
                    FilePath     = $Path
                    Source       = 'Hash'
                    Permission   = 'Hash Level'
                    IsAuthorized = $true
                }
                # Convert the hash table to a PSObject and add it to the output array
                $MegaOutputObject += New-Object -TypeName PSObject -Property $Object
            }
        }

        if ($SignedFile_FilePublisher_Objects) {
            Write-Verbose -Message 'Looping through the array of files allowed by valid signature - FilePublisher Level'
            Write-Verbose -Message "$($SignedFile_FilePublisher_Objects.count) File(s) are allowed by FilePublisher signer level." -Verbose
            foreach ($Item in $SignedFile_FilePublisher_Objects) {
                # Create a hash table with the file path and source properties
                [System.Collections.Hashtable]$Object = @{
                    FilePath     = $Item.FilePath
                    Source       = 'Signer'
                    Permission   = "FilePublisher Level - $($Item.SpecificFileNameLevel)"
                    IsAuthorized = $true
                }
                # Convert the hash table to a PSObject and add it to the output array
                $MegaOutputObject += New-Object -TypeName PSObject -Property $Object
            }
        }

        if ($SignedFile_Publisher_FilePaths) {
            Write-Verbose -Message 'Looping through the array of files allowed by valid signature - Publisher Level'
            Write-Verbose -Message "$($SignedFile_Publisher_FilePaths.count) File(s) are allowed by Publisher signer level." -Verbose
            foreach ($Path in $SignedFile_Publisher_FilePaths) {
                # Create a hash table with the file path and source properties
                [System.Collections.Hashtable]$Object = @{
                    FilePath     = $Path
                    Source       = 'Signer'
                    Permission   = 'Publisher Level'
                    IsAuthorized = $true
                }
                # Convert the hash table to a PSObject and add it to the output array
                $MegaOutputObject += New-Object -TypeName PSObject -Property $Object
            }
        }

        if ($SignedFile_SignedVersion_FilePaths) {
            Write-Verbose -Message 'Looping through the array of files allowed by valid signature - SignedVersion Level'
            Write-Verbose -Message "$($SignedFile_SignedVersion_FilePaths.count) File(s) are allowed by SignedVersion signer level." -Verbose
            foreach ($Path in $SignedFile_SignedVersion_FilePaths) {
                # Create a hash table with the file path and source properties
                [System.Collections.Hashtable]$Object = @{
                    FilePath     = $Path
                    Source       = 'Signer'
                    Permission   = 'SignedVersion Level'
                    IsAuthorized = $true
                }
                # Convert the hash table to a PSObject and add it to the output array
                $MegaOutputObject += New-Object -TypeName PSObject -Property $Object
            }
        }

        if ($SignedFile_PcaCertificateAndRootCertificate_FilePaths) {
            Write-Verbose -Message 'Looping through the array of files allowed by valid signature - PcaCertificate/RootCertificate Levels'
            Write-Verbose -Message "$($SignedFile_PcaCertificateAndRootCertificate_FilePaths.count) File(s) are allowed by PcaCertificate/RootCertificate signer levels." -Verbose
            foreach ($Path in $SignedFile_PcaCertificateAndRootCertificate_FilePaths) {
                # Create a hash table with the file path and source properties
                [System.Collections.Hashtable]$Object = @{
                    FilePath     = $Path
                    Source       = 'Signer'
                    Permission   = 'PcaCertificate / RootCertificate Levels'
                    IsAuthorized = $true
                }
                # Convert the hash table to a PSObject and add it to the output array
                $MegaOutputObject += New-Object -TypeName PSObject -Property $Object
            }
        }

        if ($SignedFile_LeafCertificate_FilePaths) {
            Write-Verbose -Message 'Looping through the array of files allowed by valid signature - LeafCertificate Level'
            Write-Verbose -Message "$($SignedFile_LeafCertificate_FilePaths.count) File(s) are allowed by LeafCertificate signer level." -Verbose
            foreach ($Path in $SignedFile_LeafCertificate_FilePaths) {
                # Create a hash table with the file path and source properties
                [System.Collections.Hashtable]$Object = @{
                    FilePath     = $Path
                    Source       = 'Signer'
                    Permission   = 'LeafCertificate Level'
                    IsAuthorized = $true
                }
                # Convert the hash table to a PSObject and add it to the output array
                $MegaOutputObject += New-Object -TypeName PSObject -Property $Object
            }
        }

        if ($SignedButNotAllowed) {
            Write-Verbose -Message 'Looping through the array of signed files that are not allowed'
            Write-Verbose -Message "$($SignedButNotAllowed.count) File(s) are signed but NOT allowed." -Verbose
            foreach ($Path in $SignedButNotAllowed) {
                # Create a hash table with the file path and source properties
                [System.Collections.Hashtable]$Object = @{
                    FilePath     = $Path
                    Source       = 'Signer'
                    Permission   = 'Not Allowed'
                    IsAuthorized = $false
                }
                # Convert the hash table to a PSObject and add it to the output array
                $MegaOutputObject += New-Object -TypeName PSObject -Property $Object
            }
        }

        if ($SignedButEKUMismatch) {
            Write-Verbose -Message 'Looping through the array of signed files with EKU mismatch'
            Write-Verbose -Message "$($SignedButEKUMismatch.count) File(s) have EKU mismatch and are NOT allowed." -Verbose
            foreach ($Path in $SignedButEKUMismatch) {
                # Create a hash table with the file path and source properties
                [System.Collections.Hashtable]$Object = @{
                    FilePath     = $Path
                    Source       = 'Signer'
                    Permission   = 'EKU requirements not met'
                    IsAuthorized = $false
                }
                # Convert the hash table to a PSObject and add it to the output array
                $MegaOutputObject += New-Object -TypeName PSObject -Property $Object
            }
        }

        if ($SignedHashMismatchFilePaths) {
            Write-Verbose -Message 'Looping through the array of signed files with hash mismatch'
            Write-Verbose -Message "$($SignedHashMismatchFilePaths.count) File(s) have Hash Mismatch and are NOT allowed." -Verbose
            foreach ($Path in $SignedHashMismatchFilePaths) {
                # Create a hash table with the file path and source properties
                [System.Collections.Hashtable]$Object = @{
                    FilePath     = $Path
                    Source       = 'Signer'
                    Permission   = 'Hash Mismatch'
                    IsAuthorized = $false
                }
                # Convert the hash table to a PSObject and add it to the output array
                $MegaOutputObject += New-Object -TypeName PSObject -Property $Object
            }
        }

        if ($SignedButUnknownObjects) {
            Write-Verbose -Message 'Looping through the array of files with unknown signature status'
            Write-Verbose -Message "$($SignedButUnknownObjects.count) File(s) have unknown signature status and are NOT allowed." -Verbose
            foreach ($Item in $SignedButUnknownObjects) {
                # Create a hash table with the file path and source properties
                [System.Collections.Hashtable]$Object = @{
                    FilePath     = $Item.FilePath
                    Source       = 'Signer'
                    Permission   = "UnknownError, $($Item.FailureReason)"
                    IsAuthorized = $false
                }
                # Convert the hash table to a PSObject and add it to the output array
                $MegaOutputObject += New-Object -TypeName PSObject -Property $Object
            }
        }

        if ($UnsignedNotAllowedFilePaths) {
            Write-Verbose -Message 'Looping through the array of unsigned files that are not allowed'
            Write-Verbose -Message "$($UnsignedNotAllowedFilePaths.count) File(s) are unsigned and are NOT allowed." -Verbose
            foreach ($Path in $UnsignedNotAllowedFilePaths) {
                # Create a hash table with the file path and source properties
                [System.Collections.Hashtable]$Object = @{
                    FilePath     = $Path
                    Source       = 'Unsigned'
                    Permission   = 'Not Allowed'
                    IsAuthorized = $false
                }
                # Convert the hash table to a PSObject and add it to the output array
                $MegaOutputObject += New-Object -TypeName PSObject -Property $Object
            }
        }

        if ($InAccessibleFilePaths) {
            Write-Verbose -Message 'Looping through the array of signed files that are not processed due to lack of permission'
            Write-Verbose -Message "$($InAccessibleFilePaths.count) File(s) are signed but not processed due to lack of permission." -Verbose
            foreach ($Path in $InAccessibleFilePaths) {
                # Create a hash table with the file path and source properties
                [System.Collections.Hashtable]$Object = @{
                    FilePath     = $Path
                    Source       = 'Signer'
                    Permission   = 'Not processed, No permission'
                    IsAuthorized = $false
                }
                # Convert the hash table to a PSObject and add it to the output array
                $MegaOutputObject += New-Object -TypeName PSObject -Property $Object
            }
        }
    }

    end {
        # If the policy contains a rule that allows all files, then return $true and exit
        if ($ShouldExit) { Return $true }

        # If the user selected the -BooleanOutput switch, then return a boolean value and don't display any more output
        if ($BooleanOutput) {
            # Get all of the allowed files
            $AllAllowedRules = $MegaOutputObject | Where-Object -FilterScript { $_.IsAuthorized -eq $true }
            # Get all of the blocked files
            $BlockedRules = $MegaOutputObject | Where-Object -FilterScript { $_.IsAuthorized -eq $false }

            Write-Verbose -Message "Allowed files: $($AllAllowedRules.count)"
            Write-Verbose -Message "Blocked files: $($BlockedRules.count)"

            # If the array of allowed files is not empty
            if (-NOT ([System.String]::IsNullOrWhiteSpace($AllAllowedRules))) {

                # If the array of blocked files is empty
                if ([System.String]::IsNullOrWhiteSpace($BlockedRules)) {
                    Write-Progress -Id 0 -Activity 'WDAC Simulation completed.' -Completed

                    # If the -Log switch is used, then stop the stopwatch and the transcription
                    if ($Log) { Stop-Log }

                    Return $true
                }
                else {
                    Write-Progress -Id 0 -Activity 'WDAC Simulation completed.' -Completed

                    # If the -Log switch is used, then stop the stopwatch and the transcription
                    if ($Log) { Stop-Log }

                    Return $false
                }
            }
            else {
                Write-Progress -Id 0 -Activity 'WDAC Simulation completed.' -Completed

                # If the -Log switch is used, then stop the stopwatch and the transcription
                if ($Log) { Stop-Log }

                Return $false
            }
        }

        # Export the output as CSV
        if ($CSVOutput) {
            $MegaOutputObject | Select-Object -Property FilePath, Source, IsAuthorized, Permission | Sort-Object -Property IsAuthorized | Export-Csv -LiteralPath (Join-Path -Path $UserConfigDir -ChildPath "WDAC Simulation Output $(Get-Date -Format "MM-dd-yyyy 'at' HH-mm-ss").csv") -Force
        }

        Write-Progress -Id 0 -Activity 'WDAC Simulation completed.' -Completed

        # Change the color of the Table header to SkyBlue
        $PSStyle.Formatting.TableHeader = "$($PSStyle.Foreground.FromRGB(135,206,235))"

        # If the -Log switch is used, then stop the stopwatch and the transcription
        if ($Log) { Stop-Log }

        # Return the final main output array as a table
        Return $MegaOutputObject | Select-Object -Property @{
            Label      = 'FilePath'
            Expression = { (Get-Item -LiteralPath $_.FilePath).Name } # Truncate the FilePath string to only show the File name. The full File path will be displayed in the CSV output file
        },
        @{
            Label      = 'Source'
            Expression =
            { switch ($_.Source) {
                    { $_ -eq 'Signer' } { $color = "$($PSStyle.Foreground.FromRGB(152,255,152))" }
                    { $_ -eq 'Hash' } { $color = "$($PSStyle.Foreground.FromRGB(255,255,49))" }
                    { $_ -eq 'Unsigned' } { $color = "$($PSStyle.Foreground.FromRGB(255,20,147))" }
                }
                "$color$($_.Source)$($PSStyle.Reset)" # Use PSStyle to reset the color
            }
        },
        @{
            Label      = 'IsAuthorized'
            Expression =
            {
                switch ($_.IsAuthorized) {
                    { $_ -eq $true } { $Color = "$($PSStyle.Foreground.FromRGB(255,0,255))"; break }
                    { $_ -eq $false } { $Color = "$($PSStyle.Foreground.FromRGB(255,165,0))$($PSStyle.Blink)"; break }
                }
                "$Color$($_.IsAuthorized)$($PSStyle.Reset)" # Use PSStyle to reset the color
            }
        },
        @{
            Label      = 'Permission'
            Expression = {
                # If the Permission starts with 'UnknownError', truncate it to 50 characters. The full string will be displayed in the CSV output file. If it does not then just display it as it is
                $_.Permission -match 'UnknownError' ? $_.Permission.Substring(0, 50) + '...' : $_.Permission
            }
        } | Sort-Object -Property IsAuthorized
    }

    <#
.SYNOPSIS
    Simulates the deployment of the WDAC policy. It returns an object that contains the file path, source, permission, and whether the file is allowed or not.
    You can use the object returned by this cmdlet to filter the results and perform other checks.

    Properties explanation:

    FilePath:       The path of the file
    Source:         The source of the file's permission, e.g., 'Signer' (For signed files only), 'Hash' (For signed and unsigned files), 'Unsigned' (For unsigned files only)
    Permission:     The reason the file is allowed or not. For files authorized by FilePublisher level, it will show the specific file name level that the file is authorized by. (https://learn.microsoft.com/en-us/windows/security/application-security/application-control/windows-defender-application-control/design/select-types-of-rules-to-create#table-3--specificfilenamelevel-options)
    IsAuthorized:   A boolean value that indicates whether the file is allowed or not.
.LINK
    https://github.com/HotCakeX/Harden-Windows-Security/wiki/Invoke-WDACSimulation
.DESCRIPTION
    Simulates the deployment of the WDAC policy by analyzing a folder and checking which of the files in the folder are allowed by a user selected policy xml file

    All of the components of the Invoke-WDACSimulation use LiteralPath
.COMPONENT
    Windows Defender Application Control, ConfigCI PowerShell module
.FUNCTIONALITY
    Simulates the deployment of the WDAC policy
.PARAMETER FolderPath
    Provide path to a folder that you want WDAC simulation to run against

    Uses LiteralPath to take the path exactly as typed including Special characters such as [ and ]

    Does not support wildcards
.PARAMETER FilePath
    Provide path to a file that you want WDAC simulation to run against

    Uses LiteralPath to take the path exactly as typed including Special characters such as [ and ]

    Does not support wildcards
.PARAMETER XmlFilePath
    Provide path to a policy xml file that you want the cmdlet to simulate its deployment and running files against it

    Uses LiteralPath to take the path exactly as typed including Special characters such as [ and ]

    Does not support wildcards
.PARAMETER Log
    Use this switch to start a transcript of the WDAC simulation and log everything displayed on the screen. Highly recommended to use the -Verbose parameter with this switch to log the verbose output as well.
.PARAMETER SkipVersionCheck
    Bypass the online version check - only to be used in rare cases
    It is used by the entire Cmdlet.
.PARAMETER Verbose
    Shows verbose output
.PARAMETER BooleanOutput
    Returns a boolean value instead of displaying the object output
.PARAMETER CSVOutput
    Exports the output to a CSV file
.INPUTS
    System.IO.FileInfo
    System.IO.DirectoryInfo
    System.Management.Automation.SwitchParameter
.OUTPUTS
    System.Object[]
    System.Boolean
.EXAMPLE
    Invoke-WDACSimulation -FolderPath 'C:\Windows\System32' -XmlFilePath 'C:\Users\HotCakeX\Desktop\Policy.xml'
    This example will simulate the deployment of the policy.xml file against the C:\Windows\System32 folder
.NOTES
    WDAC templates such as 'Default Windows' and 'Allow Microsoft' don't have CertPublisher element in their Signers because they don't target a leaf certificate,
    thus they weren't created using FilePublisher level, they were created using Publisher or Root certificate levels to allow Microsoft's wellknown certificates.
#>
}

# Importing argument completer ScriptBlocks
. "$ModuleRootPath\CoreExt\ArgumentCompleters.ps1"
Register-ArgumentCompleter -CommandName 'Invoke-WDACSimulation' -ParameterName 'FolderPath' -ScriptBlock $ArgumentCompleterFolderPathsPicker
Register-ArgumentCompleter -CommandName 'Invoke-WDACSimulation' -ParameterName 'XmlFilePath' -ScriptBlock $ArgumentCompleterXmlFilePathsPicker
Register-ArgumentCompleter -CommandName 'Invoke-WDACSimulation' -ParameterName 'FilePath' -ScriptBlock $ArgumentCompleterAnyFilePathsPicker

# SIG # Begin signature block
# MIILkgYJKoZIhvcNAQcCoIILgzCCC38CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDw7Dg/E7IqvgHr
# e2+EDr7FqVMqM5xvt+/JEcb5p91B9KCCB9AwggfMMIIFtKADAgECAhMeAAAABI80
# LDQz/68TAAAAAAAEMA0GCSqGSIb3DQEBDQUAME8xEzARBgoJkiaJk/IsZAEZFgNj
# b20xIjAgBgoJkiaJk/IsZAEZFhJIT1RDQUtFWC1DQS1Eb21haW4xFDASBgNVBAMT
# C0hPVENBS0VYLUNBMCAXDTIzMTIyNzExMjkyOVoYDzIyMDgxMTEyMTEyOTI5WjB5
# MQswCQYDVQQGEwJVSzEeMBwGA1UEAxMVSG90Q2FrZVggQ29kZSBTaWduaW5nMSMw
# IQYJKoZIhvcNAQkBFhRob3RjYWtleEBvdXRsb29rLmNvbTElMCMGCSqGSIb3DQEJ
# ARYWU3B5bmV0Z2lybEBvdXRsb29rLmNvbTCCAiIwDQYJKoZIhvcNAQEBBQADggIP
# ADCCAgoCggIBAKb1BJzTrpu1ERiwr7ivp0UuJ1GmNmmZ65eckLpGSF+2r22+7Tgm
# pEifj9NhPw0X60F9HhdSM+2XeuikmaNMvq8XRDUFoenv9P1ZU1wli5WTKHJ5ayDW
# k2NP22G9IPRnIpizkHkQnCwctx0AFJx1qvvd+EFlG6ihM0fKGG+DwMaFqsKCGh+M
# rb1bKKtY7UEnEVAsVi7KYGkkH+ukhyFUAdUbh/3ZjO0xWPYpkf/1ldvGes6pjK6P
# US2PHbe6ukiupqYYG3I5Ad0e20uQfZbz9vMSTiwslLhmsST0XAesEvi+SJYz2xAQ
# x2O4n/PxMRxZ3m5Q0WQxLTGFGjB2Bl+B+QPBzbpwb9JC77zgA8J2ncP2biEguSRJ
# e56Ezx6YpSoRv4d1jS3tpRL+ZFm8yv6We+hodE++0tLsfpUq42Guy3MrGQ2kTIRo
# 7TGLOLpayR8tYmnF0XEHaBiVl7u/Szr7kmOe/CfRG8IZl6UX+/66OqZeyJ12Q3m2
# fe7ZWnpWT5sVp2sJmiuGb3atFXBWKcwNumNuy4JecjQE+7NF8rfIv94NxbBV/WSM
# pKf6Yv9OgzkjY1nRdIS1FBHa88RR55+7Ikh4FIGPBTAibiCEJMc79+b8cdsQGOo4
# ymgbKjGeoRNjtegZ7XE/3TUywBBFMf8NfcjF8REs/HIl7u2RHwRaUTJdAgMBAAGj
# ggJzMIICbzA8BgkrBgEEAYI3FQcELzAtBiUrBgEEAYI3FQiG7sUghM++I4HxhQSF
# hqV1htyhDXuG5sF2wOlDAgFkAgEIMBMGA1UdJQQMMAoGCCsGAQUFBwMDMA4GA1Ud
# DwEB/wQEAwIHgDAMBgNVHRMBAf8EAjAAMBsGCSsGAQQBgjcVCgQOMAwwCgYIKwYB
# BQUHAwMwHQYDVR0OBBYEFOlnnQDHNUpYoPqECFP6JAqGDFM6MB8GA1UdIwQYMBaA
# FICT0Mhz5MfqMIi7Xax90DRKYJLSMIHUBgNVHR8EgcwwgckwgcaggcOggcCGgb1s
# ZGFwOi8vL0NOPUhPVENBS0VYLUNBLENOPUhvdENha2VYLENOPUNEUCxDTj1QdWJs
# aWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2aWNlcyxDTj1Db25maWd1cmF0aW9u
# LERDPU5vbkV4aXN0ZW50RG9tYWluLERDPWNvbT9jZXJ0aWZpY2F0ZVJldm9jYXRp
# b25MaXN0P2Jhc2U/b2JqZWN0Q2xhc3M9Y1JMRGlzdHJpYnV0aW9uUG9pbnQwgccG
# CCsGAQUFBwEBBIG6MIG3MIG0BggrBgEFBQcwAoaBp2xkYXA6Ly8vQ049SE9UQ0FL
# RVgtQ0EsQ049QUlBLENOPVB1YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNlcnZp
# Y2VzLENOPUNvbmZpZ3VyYXRpb24sREM9Tm9uRXhpc3RlbnREb21haW4sREM9Y29t
# P2NBQ2VydGlmaWNhdGU/YmFzZT9vYmplY3RDbGFzcz1jZXJ0aWZpY2F0aW9uQXV0
# aG9yaXR5MA0GCSqGSIb3DQEBDQUAA4ICAQA7JI76Ixy113wNjiJmJmPKfnn7brVI
# IyA3ZudXCheqWTYPyYnwzhCSzKJLejGNAsMlXwoYgXQBBmMiSI4Zv4UhTNc4Umqx
# pZSpqV+3FRFQHOG/X6NMHuFa2z7T2pdj+QJuH5TgPayKAJc+Kbg4C7edL6YoePRu
# HoEhoRffiabEP/yDtZWMa6WFqBsfgiLMlo7DfuhRJ0eRqvJ6+czOVU2bxvESMQVo
# bvFTNDlEcUzBM7QxbnsDyGpoJZTx6M3cUkEazuliPAw3IW1vJn8SR1jFBukKcjWn
# aau+/BE9w77GFz1RbIfH3hJ/CUA0wCavxWcbAHz1YoPTAz6EKjIc5PcHpDO+n8Fh
# t3ULwVjWPMoZzU589IXi+2Ol0IUWAdoQJr/Llhub3SNKZ3LlMUPNt+tXAs/vcUl0
# 7+Dp5FpUARE2gMYA/XxfU9T6Q3pX3/NRP/ojO9m0JrKv/KMc9sCGmV9sDygCOosU
# 5yGS4Ze/DJw6QR7xT9lMiWsfgL96Qcw4lfu1+5iLr0dnDFsGowGTKPGI0EvzK7H+
# DuFRg+Fyhn40dOUl8fVDqYHuZJRoWJxCsyobVkrX4rA6xUTswl7xYPYWz88WZDoY
# gI8AwuRkzJyUEA07IYtsbFCYrcUzIHME4uf8jsJhCmb0va1G2WrWuyasv3K/G8Nn
# f60MsDbDH1mLtzGCAxgwggMUAgEBMGYwTzETMBEGCgmSJomT8ixkARkWA2NvbTEi
# MCAGCgmSJomT8ixkARkWEkhPVENBS0VYLUNBLURvbWFpbjEUMBIGA1UEAxMLSE9U
# Q0FLRVgtQ0ECEx4AAAAEjzQsNDP/rxMAAAAAAAQwDQYJYIZIAWUDBAIBBQCggYQw
# GAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGC
# NwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQx
# IgQgUZX1J1xaIWC9ZOJoF/jPAxpoJ7BbI99W9WxCgIj9Cx0wDQYJKoZIhvcNAQEB
# BQAEggIAD79kNnFWrAT1sA6ryRQZ3UUEcjjZbRDnTZ1zov3ipjQJ1DviypEabdcS
# QNBf/uHXH9d2cFLwmTCej98J0DGxmA4N17u7WOdXip34keS2HRItvpJmpjnsPrVr
# SdpA1hShbyTYnzG91qIwF4+1U7fcXN4quyRH63+B6WSw9qI0+pEU8b32EFfQoN+V
# uZdnAtngssjdLzlx13HMlO8A6ww7reP3EGbLNtyjA5gRPUdNWYY+1brkLID9X4hD
# N0OpovjZe0DNibqZgnQipUqT8oJGWQXmLfI6kL+OaTSSD+BCOQxHWlA6jE+Ruuom
# zOvGlFs1r9eHPo4LscEu4QKUyJCT2eJZloqt8d7dQdnhqPTyOK1FP/lepdL7btYy
# y06O6F82/KIHmr2SU+lT3sn4ceUiFHsvZVCMSk8/QMO64MJiBJqCZ8ZLR73kaDOL
# j/PkHpaALRo2IlfzBJan7g0GWvMEw2ZR+rexxDctwG6IooLVcHD3J3/WiWpo27eT
# f/JzPslSrCsWJzMXqbNMiCqCNCzPMMWsSjJJLH6J5T189XtkaGROA75efsZSQn+s
# mmPpEZWK6gOCnf3R54npwyN6CFGG8g5iq91789cvYmSFNetmfEgtVtbSggecX2gx
# xZXPL5Lxk9on42Lfp8EHq/9t4hEGWQzuDHKa5ztTUTrjQ3bkts8=
# SIG # End signature block
