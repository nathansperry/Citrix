
#Requires -Version 3.0

<#
    .SYNOPSIS
    This script is designed to replicate some of the functionality of Citrix Smart Scale.

    .DESCRIPTION
    This script is designed to either leave a % of VDA's powered on, and power off the rest during off-peak hours, where there are no active sessions, or
    power on a % of VDA's during peak hours. Script should be invoked by a schedule task on the Delivery Controller.

    .EXAMPLE
    ' Power off machines in the 'XA718-EU' delivery group, leaving 1% of machines running outside of the peak hours i.e. 6am - 6pm. If any
    ' machines have active sessions running, they will not be powered off:
    .\VirtualEngine.XASmartScale.ps1 -XAShutdown -DeliveryGroup 'XA718-EU' -PercentageLeaveRunning 1 -PeakStart 6 -PeakEnd 18 -Verbose

    .EXAMPLE
    ' Power on 100% of the machines in the 'XA718-EU' delivery group, inside of the peak hours i.e. 6am - 6pm. If any of the machines
    ' are in maintenance mode this will be turned off:
    .\VirtualEngine.XASmartScale.ps1 -XAStartUp -DeliveryGroup 'XA718-EU' -PeakStart 6 -PeakEnd 18 -PercentageStartUp 100 -Verbose

    .EXAMPLE
    ' Test power off machines in the 'XA718-EU' delivery group, leaving 1% of machines running outside of the peak hours i.e. 6am - 6pm.
    ' No power actions will be invoked in this example:
    .\VirtualEngine.XASmartScale.ps1 -XAShutdown -DeliveryGroup 'XA718-EU' -PercentageLeaveRunning 1 -PeakStart 6 -PeakEnd 18 -TestMode -Verbose

    .EXAMPLE
    ' Test power on of 100% of the machines in the 'XA718-EU' delivery group, inside of the peak hours i.e. 6am - 6pm. If any of the machines
    ' are in maintenance mode this will be turned off. No power actions will be invoked in this example:
    .\VirtualEngine.XASmartScale.ps1 -XAStartUp -DeliveryGroup 'XA718-EU' -PeakStart 6 -PeakEnd 18 -PercentageStartUp 100 -TestMode -Verbose    

    .LINK
    https://virtualengine.co.uk

    NAME: VirtualEngine.XASmartScale
    AUTHOR: Nathan Sperry, Virtual Engine
    LASTEDIT: 04/09/2018
    VERSI0N : 1.0
    WEBSITE: http://www.virtualengine.co.uk

#>

[CmdletBinding()]
param (

    [Parameter(ParameterSetName='1')] [Switch] $XAShutdown, ## Perform power off operations
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [String] $DeliveryGroup, ## Delivery Group Name
    [Parameter(Mandatory,ParameterSetName='1')] [ValidateNotNullOrEmpty()] [String] $PercentageLeaveRunning = 1, ## % of VDA's is stay powered on default is 1%
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [int] $PeakStart = 6, ## Hour when start Of Peak Period
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [int] $PeakEnd = 18, ## Hour when end of Peak Period
    [Parameter(ParameterSetName='2')] [Switch] $XAStartUp, ## Perform power on operations
    [Parameter(Mandatory,ParameterSetName='2')] [ValidateNotNullOrEmpty()] [String] $PercentageStartUp = 100, ## % of VDA's to powered on default is 10%
    [Parameter()] [Switch] $TestMode ## Do not perform any actions just log events

)

function Write-CustomEventLog {
    [CmdletBinding()]
    param (
        [Parameter()] [ValidateNotNullOrEmpty()] [String] $LogName = 'Virtual Engine',
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [String] $Source,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [Int32] $EventID,
        [Parameter(Mandatory)] [ValidateSet('Information','Warning','Error')] [String] $EntryType,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [String] $Message
        
    )

    Begin{

        $Event = @{
            LogName = $LogName
            Source = $Source
            EventId = $EventID
            EntryType = $EntryType
            Message = $Message
        };
    }


    Process{

        Write-EventLog @Event;

    }
}

function Invoke-PowerAction {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [ValidateSet('Reset','Restart','Resume','Shutdown','Suspend','TurnOff','TurnOn')] [String] $PowerAction,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)] [ValidateNotNullOrEmpty()] $Machines
        
    )

    Begin{}

    Process {
        
        $Machines | ForEach-Object {
            ## ActualPriority: specifies an initial priority for the action in the queue. This priority is the current action priority;
            ##    the 'base' priority for actions created via this cmdlet is always 30. Numerically lower priority values indicate more
            ##    important actions that will be processed in preference to actions with numerically higher priority settings.
            ## Action: Reset, Restart, Resume, Shutdown, Suspend, TurnOff, TurnOn

                
                ## if maintenance mode is on, then turn it off regardless
                if (($PowerAction -eq 'TurnOn') -and ($_.InMaintenanceMode -eq $true)) {

                    $message = ('{0} is in maintenance mode attempting to turn off.' -f $_.MachineName);
                    Write-Verbose $message;
                    Write-CustomEventLog -Source $Source -EventID 1002 -EntryType Information -Message $message;

                    if (-not ($TestMode)) {Set-BrokerMachine -MachineName $_.MachineName -InMaintenanceMode $false | Out-Null;};

                }

                $message = ('Attempting to {1} {0}.' -f $_.MachineName,$PowerAction);
                Write-Verbose $message;
                Write-CustomEventLog -Source $Source -EventID 1002 -EntryType Information -Message $message;
            
                if (-not ($TestMode)) {New-BrokerHostingPowerAction -MachineName $_.MachineName -Action $PowerAction | Out-Null;};

        };

    };
    
    End{}

}

function Invoke-XAShutdown {

    [CmdletBinding()]
    param (

        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [String] $DeliveryGroup,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [String] $PercentageLeaveRunning,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [bool] $Peak
        #[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [int] $PeakEnd
    )

        Begin {

            $Source = 'Citrix Power Actions (PowerOff)' #EventLog Source Name
        }

        Process {

            if (-not ($Peak)) {

                ## return all machines in the desired delivery group
                $TotalMachines = Get-BrokerMachine | Where-Object {$_.DesktopGroupName -eq $DeliveryGroup};
 
                ## condtion 1    
                if ($null -eq $TotalMachines){
                    
                    $condition = 1
                    ## Something has gone wrong
                    $message = ('({1}) Something has gone wrong as ''{0}'' Delivery Group contains no machines!!' -f $DeliveryGroup,$condition);             
                    Write-CustomEventLog -Source $Source -EventID 1100 -EntryType Error -Message $message;
                    Write-Error $message;
                    exit;

                }

                ## number of machines in the delivery group
                $CountMachines = ($TotalMachines).Count;

                    $message = ('Machines in the ''{1}'' Delivery Group [{0}].' -f $TotalMachines.Count,$DeliveryGroup);
                    Write-Verbose -Message $message;
                    Write-CustomEventLog -Source $Source -EventID 1000 -EntryType Information -Message $message;

                ## number of machines to always leave running (rounding up)
                $NumberAlwaysOn = [math]::ceiling(($PercentageLeaveRunning/100)*$CountMachines);

                    $message = ('Number of machines to always leave running based on {1}% [{0}].' -f $NumberAlwaysOn,$PercentageLeaveRunning);
                    Write-Verbose $message;
                    Write-CustomEventLog -Source $Source -EventID 1000 -EntryType Information -Message $message;

                $PoweredOn = $TotalMachines | Where-Object {$_.PowerState -in 'On','TurningOn'};

                    $message = ('Number of powered on machines [{0}].' -f $PoweredOn.Count);
                    Write-Verbose $message;
                    Write-CustomEventLog -Source $Source -EventID 1000 -EntryType Information -Message $message;

                $PoweredOff = $TotalMachines | Where-Object {$_.PowerState -in 'Off','TurningOff'};

                    $message = ('Number of powered off machines [{0}].' -f $PoweredOff.Count);
                    Write-Verbose $message;
                    Write-CustomEventLog -Source $Source -EventID 1000 -EntryType Information -Message $message;                 

                $NotInUse = $TotalMachines | Where-Object {$_.SessionCount -eq 0 -and
                                                            $_.PowerState -eq 'On' -and
                                                            $_.PowerActionPending -eq $false};

                    $message = ('Machines with no active sessions [{0}].' -f $NotInUse.Count);
                    Write-Verbose $message;
                    Write-CustomEventLog -Source $Source -EventID 1000 -EntryType Information -Message $message;    

                $InUse = $TotalMachines | Where-Object {$_.SessionCount -ge 1 -and
                                                        $_.PowerState -eq 'On' -and
                                                        $_.PowerActionPending -eq $false};

                    $message = ('Machines with active sessions [{0}].' -f $InUse.Count);
                    Write-Verbose $message;
                    Write-CustomEventLog -Source $Source -EventID 1000 -EntryType Information -Message $message;    

                ## condtion 1    
                if ($null -eq $TotalMachines){
                    
                    $condition = 1
                    ## Something has gone wrong
                    $message = ('({1}) Something has gone wrong as ''{0}'' Delivery Group contains no machines!!' -f $DeliveryGroup,$condition);             
                    Write-CustomEventLog -Source $Source -EventID 1100 -EntryType Error -Message $message;
                    Write-Error $message;

                }
                ## condtion 2
                elseif ($PoweredOn.Count -eq 0){
                    
                    $condition = 2
                    $message = ('({0}) Something not right as all machines are powered off' -f,$condition);             
                    Write-Warning $message;
                    Write-CustomEventLog -Source $Source -EventID 1100 -EntryType Warning -Message $message;

                    $message =  ('({1}) Attempting to power on [{0}] machines.' -f $NumberAlwaysOn,$condition);
                    Write-Verbose $message;
                    Write-CustomEventLog -Source 'Citrix Power Actions (PowerOn)' -EventID 1002 -EntryType Information -Message $message;
                    
                    $Machines = $TotalMachines | Select-Object -First $NumberAlwaysOn;
                    Invoke-PowerAction -PowerAction TurnOn -Machines $Machines;

                }
                ## condtion 3
                elseif ($PoweredOn.Count -eq $NumberAlwaysOn) {
                    
                    $condition = 3
                    $message = ('({1}) Minimum number of machines [{0}] are already running, therefore exiting.' -f $NumberAlwaysOn,$condition);
                    Write-Verbose $message;
                    Write-CustomEventLog -Source $Source -EventID 1000 -EntryType Information -Message $message; 
                    
                }         
                # condition 4
                elseif (($InUse.Count -eq $PoweredOn.Count) -and ($InUse.Count -ge $NumberAlwaysOn)){
                    
                    $condition = 4
                    $message = ('({1}) Minimum number of machines [{0}] are already running, therefore exiting.' -f $NumberAlwaysOn,$condition);
                    Write-Verbose $message;
                    Write-CustomEventLog -Source $Source -EventID 1000 -EntryType Information -Message $message; 
                    
                }
                # condition 5
                elseif (($InUse.Count -eq $PoweredOn.Count) -and ($PoweredOn.Count -ge $NumberAlwaysOn)){
                    
                    $condition = 5
                    $message = ('({1}) Minimum number of machines [{0}] are already running, therefore exiting.' -f $NumberAlwaysOn,$condition);
                    Write-Verbose $message;
                    Write-CustomEventLog -Source $Source -EventID 1000 -EntryType Information -Message $message; 
                    
                }                                  
                ## condtion 6
                elseif ($PoweredOn.Count -gt $NumberAlwaysOn) {
                           
                    ## condtion 6.1
                    if ($InUse.Count -ge $NumberAlwaysOn) {

                        $condition = 6.1
                        $message = ('({1}) We need to shutdown [{0}] machines' -f $NotInUse.Count,$condition);
                        Write-Verbose $message;
                        Write-CustomEventLog -Source $Source -EventID 1002 -EntryType Information -Message $message; 

                        Invoke-PowerAction -PowerAction Shutdown -Machines $NotInUse;
                        <#
                        $condition = 4.1
                        $message = ('[{1}] Minimum number of machines [{0}] are already running, therefore exiting.' -f $NumberAlwaysOn,$condition);
                        Write-Verbose $message;
                        Write-CustomEventLog -Source $Source -EventID 1000 -EntryType Information -Message $message; 
                        #>
                    }
                    ## condtion 6.2
                    elseif ($NotInUse.Count -gt $NumberAlwaysOn) {
                        
                        $condition = 6.2
                        #$x = $NotInUse.Count - $InUse.Count;
                        $x = $NotInUse.Count - $NumberAlwaysOn;
                        $Machines = $NotInUse | Select-Object -First $x

                        $message = ('({1}) We need to shutdown [{0}] machines' -f $x,$condition);
                        Write-Verbose $message;
                        Write-CustomEventLog -Source $Source -EventID 1002 -EntryType Information -Message $message;

                        Invoke-PowerAction -PowerAction Shutdown -Machines $Machines;
                    }
                    ## condtion 6.3
                    elseif ($NotInUse.Count -eq $NumberAlwaysOn) {
                        
                        $condition = 6.3
                        #$x = $NotInUse.Count - $InUse.Count;
                        $x = $PoweredOn.Count - $NotInUse.Count;
                        $Machines = $NotInUse | Select-Object -First $x

                        $message = ('({1}) We need to shutdown [{0}] machines' -f $x,$condition);
                        Write-Verbose $message;
                        Write-CustomEventLog -Source $Source -EventID 1002 -EntryType Information -Message $message;

                        Invoke-PowerAction -PowerAction Shutdown -Machines $Machines;
                    }                    
                }
                ## condtion 7
                elseif (($InUse.Count -eq 0) -and ($PoweredOn.Count -gt $NumberAlwaysOn)) {
                    
                    $condition = 7
                    $x = $NotInUse.Count - $NumberAlwaysOn;
                    $Machines = $NotInUse | Select-Object -First $x

                    $message = ('({1}) We need to shutdown [{0}] machines' -f $x,$condition);
                    Write-Verbose $message;
                    Write-CustomEventLog -Source $Source -EventID 1002 -EntryType Information -Message $message;

                    Invoke-PowerAction -PowerAction Shutdown -Machines $Machines;
                
                }
                ## condtion 8
                elseif ($InUse.Count -ge $NumberAlwaysOn) {
                    
                    $condition = 8
                    $message = ('({1}) We need to shutdown [{0}] machines' -f,$NotInUse.Count,$condition);
                    Write-Verbose $message;
                    Write-CustomEventLog -Source $Source -EventID 1002 -EntryType Information -Message $message;

                    Invoke-PowerAction -PowerAction Shutdown -Machines $NotInUse;
                    
                }
                ## condtion 9
                ## NEEDS WORK
                elseif ($PoweredOn.Count -lt $NumberAlwaysOn) {
                    
                    $condition = 9
                    $x = $NumberAlwaysOn - $PoweredOn.Count;

                    $message =  ('[{1}] More machines need to be powered on [{0}].' -f $x,$condition);
                    Write-Verbose $message;
                    Write-CustomEventLog -Source $Source -EventID 1002 -EntryType Information -Message $message;                    

                    $Machines = $PoweredOff | Select-Object -First $x;

                    $message =  ('[{1}] Attempting to power on [{0}] machines.' -f $Machines.Count,$condition);
                    Write-Verbose $message;
                    Write-CustomEventLog -Source 'Citrix Power Actions (PowerOn)' -EventID 1002 -EntryType Information -Message $message; 

                    Invoke-PowerAction -PowerAction TurnOn -Machines $Machines;
                    
                    #$message =  ('({1}) More machines need to be powered on.' -f $x,$condition);
                    #Write-Verbose $message;
                    #Write-CustomEventLog -Source $Source -EventID 1002 -EntryType Information -Message $message;
                
                }
            }
            else {

                $message = ('This task can only be executed between the hours of {0} and {1}' -f $PeakStart,$PeakEnd);
                Write-Warning $message;

                Write-CustomEventLog -Source $Source -EventID 1100 -EntryType Warning -Message $message;
            }

        }

        End{}

}

function Invoke-XAStartUp {

    [CmdletBinding()]
    param (

        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [String] $DeliveryGroup,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [String] $PercentageStartUp,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [bool] $Peak

    )


    Begin {

            $Source = 'Citrix Power Actions (PowerOn)'

            ## return all machines in the desired delivery group
            $TotalMachines = Get-BrokerMachine | Where-Object {$_.DesktopGroupName -eq $DeliveryGroup};
            
            ## condtion 1    
            if ($null -eq $TotalMachines){
                        
                $condition = 1
                ## Something has gone wrong
                $message = ('({1}) Something has gone wrong as ''{0}'' Delivery Group contains no machines!!' -f $DeliveryGroup,$condition);             
                Write-CustomEventLog -Source $Source -EventID 1100 -EntryType Error -Message $message;
                Write-Error $message;
                exit;
            
            }            

            ## number of machines in the delivery group
            $CountMachines = ($TotalMachines).Count;
            
                    $message = ('Machines in the ''{1}'' Delivery Group [{0}].' -f $TotalMachines.Count,$DeliveryGroup);
                    Write-Verbose -Message $message;
                    Write-CustomEventLog -Source $Source -EventID 1000 -EntryType Information -Message $message;
            
             ## number of machines to always leave running (rounding up)
             $NumberAlwaysOn = [math]::ceiling(($PercentageStartUp/100)*$CountMachines);
            
                    $message = ('Number of machines to always leave powered on [{0}] based on {1}%.' -f $NumberAlwaysOn,$PercentageStartUp);
                    Write-Verbose $message;
                    Write-CustomEventLog -Source $Source -EventID 1000 -EntryType Information -Message $message;
            
            $PoweredOn = $TotalMachines | Where-Object {$_.PowerState -in 'On','TurningOn'};
            
                                $message = ('Number of powered on machines [{0}].' -f $PoweredOn.Count);
                                Write-Verbose $message;
                                Write-CustomEventLog -Source $Source -EventID 1000 -EntryType Information -Message $message;
            
            $PoweredOff = $TotalMachines | Where-Object {$_.PowerState -in 'Off','TurningOff'};
            
                                $message = ('Number of powered off machines [{0}].' -f $PoweredOff.Count);
                                Write-Verbose $message;
                                Write-CustomEventLog -Source $Source -EventID 1000 -EntryType Information -Message $message;                 
            
            $NotInUse = $TotalMachines | Where-Object {$_.SessionCount -eq 0 -and
                                                                        $_.PowerState -eq 'On' -and
                                                                        $_.PowerActionPending -eq $false};
            
                                $message = ('Machines with no active sessions [{0}].' -f $NotInUse.Count);
                                Write-Verbose $message;
                                Write-CustomEventLog -Source $Source -EventID 1000 -EntryType Information -Message $message;    
            
            $InUse = $TotalMachines | Where-Object {$_.SessionCount -ge 1 -and
                                                                    $_.PowerState -eq 'On' -and
                                                                    $_.PowerActionPending -eq $false};
            
                                $message = ('Machines with active sessions [{0}].' -f $InUse.Count);
                                Write-Verbose $message;
                                Write-CustomEventLog -Source $Source -EventID 1000 -EntryType Information -Message $message; 

    }

    Process{


        ## condtion 1    
        if ($null -eq $TotalMachines){
                    
            $condition = 1
            ## Something has gone wrong
            $message = ('({1}) Something has gone wrong as ''{0}'' Delivery Group contains no machines!!' -f $DeliveryGroup,$condition);             
            Write-CustomEventLog -Source $Source -EventID 1100 -EntryType Error -Message $message;
            Write-Error $message;
        
        }
        else{

            If ($Peak) {

                If ($PoweredOn.Count -ge $NumberAlwaysOn) {
                    
                    $condition = 2.1
                    $message = ('({1}) The minimum number of machines [{0}] are already powered on, therefore exiting.' -f $NumberAlwaysOn,$condition);
                    Write-CustomEventLog -Source $Source -EventID 1001 -EntryType Information -Message $message;
                    Write-Verbose $message;
                }
                elseif ($PoweredOn.Count -lt $NumberAlwaysOn) {

                    $condition = 2.2
                    $x = $NumberAlwaysOn - $PoweredOn.Count
                    $Machines = $PoweredOff | Select-Object -First $x

                    $message = ('({2}) Machine count running [{1}] is less than minimum required [{0}].' -f $NumberAlwaysOn,$PoweredOn.Count,$condition);
                    Write-CustomEventLog -Source $Source -EventID 1001 -EntryType Information -Message $message;
                    Write-Verbose $message;

                    $message = ('({1}) Attempting to power on [{0}] machines.' -f $x,$condition);
                    Write-CustomEventLog -Source $Source -EventID 1001 -EntryType Information -Message $message;
                    Write-Verbose $message;

                    Invoke-PowerAction -PowerAction TurnOn -Machines $Machines;

                }

            }
            else {

                $message = ('This task can only be executed between the hours of {0} and {1}' -f $PeakStart,$PeakEnd);
                Write-Warning $message;

                Write-CustomEventLog -Source $Source -EventID 1100 -EntryType Warning -Message $message;

            }

        }

    }

    End{}
}

Add-PSSnapin -Name Citrix.Broker.Admin.V2;

## check if running in peak or off peak hours
$hour = (Get-date).Hour
$day = (Get-date).DayOfWeek

If ($hour -ge $PeakStart -and $hour -lt $PeakEnd) {

    $Peak = $true;
}
elseif ($hour -ge $PeakEnd){

    $Peak = $false;
}
elseif ($hour -lt $PeakStart){

    $Peak = $false;
}

## check if running on a weekend
If ($day -eq 'Saturday' -or $day -eq 'Sunday') {

    $Weekend = $true;
}

$LogName = 'Virtual Engine';

## create custom event logs to hold events from this script.
## these only need to run the first time manually and with an elevated powershell console
##New-EventLog -LogName 'Virtual Engine' -Source 'Citrix Power Actions (PowerOn)'
##New-EventLog -LogName 'Virtual Engine' -Source 'Citrix Power Actions (PowerOff)'

## invoke shutdown of machines outside of core business hours, as per schedule, and leaving a % running.
If ($XAShutdown -and (-not $Peak)) {

    Invoke-XAShutdown -DeliveryGroup $DeliveryGroup -PercentageLeaveRunning $PercentageLeaveRunning -Peak $Peak;

}
elseif (($XAShutdown -and $Peak)) {

    $message = ('This task can only be executed between the hours of {0} and {1}' -f $PeakStart,$PeakEnd);
    Write-Warning $message;

    Write-CustomEventLog -Source 'Citrix Power Actions (PowerOff)' -EventID 1100 -EntryType Warning -Message $message;

}

## invoke power on a % of machines in peak hours, but not on the weekend.
If (($XAStartUp -and $Peak) -and (-not ($Weekend))){

    Invoke-XAStartUp -DeliveryGroup $DeliveryGroup -PercentageStartUp $PercentageStartUp -Peak $Peak;

}
elseif (($XAStartUp) -and (-not $Peak) -or ($Weekend)) {

    $message = ('This task can only be executed between the hours of {0} and {1} and not at the weekend' -f $PeakStart,$PeakEnd);
    Write-Warning $message;

    Write-CustomEventLog -Source 'Citrix Power Actions (PowerOn)' -EventID 1100 -EntryType Warning -Message $message;

}