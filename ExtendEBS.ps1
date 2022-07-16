$DLetter = Read-Host "Please provide the drive to be increased"
$server = Read-Host "Please provide the server name"
$VolumeId = Invoke-Command -ComputerName $server -ScriptBlock {
$Results = @()
Get-disk | ForEach-Object {
  $DriveLetter = $null
  $VolumeName = $null

  $DiskDrive = $_
  $Disk = $_.Number
  $Partitions = $_.NumberOfPartitions
  $EbsVolumeID = $_.SerialNumber -replace "_[^ ]*$" -replace "vol", "vol-"
  Get-Partition -DiskId $_.Path | ForEach-Object {
    if ($_.DriveLetter -ne "") {
      $DriveLetter = $_.DriveLetter
      $VolumeName = (Get-PSDrive | Where-Object {$_.Name -eq $DriveLetter}).Description
    }
  } 

  If ($DiskDrive.path -like "*PROD_PVDISK*") {
    $BlockDeviceName = Convert-SCSITargetIdToDeviceName((Get-WmiObject -Class Win32_Diskdrive | Where-Object {$_.DeviceID -eq ("\\.\PHYSICALDRIVE" + $DiskDrive.Number) }).SCSITargetId)
    $BlockDeviceName = "/dev/" + $BlockDeviceName
    $BlockDevice = $BlockDeviceMappings | Where-Object { $BlockDeviceName -like "*"+$_.DeviceName+"*" }
    $EbsVolumeID = $BlockDevice.Ebs.VolumeId 
    $VirtualDevice = If ($VirtualDeviceMap.ContainsKey($BlockDeviceName)) { $VirtualDeviceMap[$BlockDeviceName] } Else { $null }
  }
  ElseIf ($DiskDrive.path -like "*PROD_AMAZON_EC2_NVME*") {
    $BlockDeviceName = Get-EC2InstanceMetadata "meta-data/block-device-mapping/ephemeral$((Get-WmiObject -Class Win32_Diskdrive | Where-Object {$_.DeviceID -eq ("\\.\PHYSICALDRIVE"+$DiskDrive.Number) }).SCSIPort - 2)"
    $BlockDevice = $null
    $VirtualDevice = If ($VirtualDeviceMap.ContainsKey($BlockDeviceName)) { $VirtualDeviceMap[$BlockDeviceName] } Else { $null }
  }
  ElseIf ($DiskDrive.path -like "*PROD_AMAZON*") {
    $BlockDevice = ""
    $BlockDeviceName = ($BlockDeviceMappings | Where-Object {$_.ebs.VolumeId -eq $EbsVolumeID}).DeviceName
    $VirtualDevice = $null
  }
  Else {
    $BlockDeviceName = $null
    $BlockDevice = $null
    $VirtualDevice = $null
  }
  $Properties = @{
    Disk          = $Disk;
    Partitions    = $Partitions;
    DriveLetter   = If ($DriveLetter -eq $null) { "N/A" } Else { $DriveLetter };
    EbsVolumeId   = If ($EbsVolumeID -eq $null) { "N/A" } Else { $EbsVolumeID };
    Device        = If ($BlockDeviceName -eq $null) { "N/A" } Else { $BlockDeviceName };
    VirtualDevice = If ($VirtualDevice -eq $null) { "N/A" } Else { $VirtualDevice };
    VolumeName    = If ($VolumeName -eq $null) { "N/A" } Else { $VolumeName };
  } 
  $Results += New-Object psobject -Property $Properties
}
$Results | ?{$_.DriveLetter -eq $using:DLetter} | Select -ExpandProperty EbsVolumeId
}

[int]$SizetoIncrease = Read-Host "Please provide the size you want to increase in GB"
$CurrentSize = (Get-EC2Volume -Volume $VolumeId).Size
$NewSize = $SizetoIncrease + $CurrentSize
Edit-EC2Volume -VolumeId $VolumeId -Size $NewSize | Out-Null
$ModifiedSize = (Get-EC2Volume -Volume $VolumeId).Size

While ($ModifiedSize -ne $NewSize) {
    Start-Sleep 5
    $ModifiedSize = (Get-EC2Volume -Volume $VolumeId).Size
}

Write-Host "Volume:$VolumeId is resized to size:$NewSize" -ForegroundColor Green

Invoke-Command -ComputerName $server -ScriptBlock { Update-HostStorageCache 
$size = Get-PartitionSupportedSize -DriveLetter $using:DLetter
Resize-Partition -DriveLetter $using:DLetter -Size $size.SizeMax
}