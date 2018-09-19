#Requires -Version 3.0

<#
    .SYNOPSIS
    This script is designed to either send a Notification, Logoff or Restart a XenDesktop Hosted Virtual Desktop.

    .DESCRIPTION
    This script is designed to either send a Notification, Logoff or Restart a XenDesktop Hosted Virtual Desktop.

    .LINK
    http://virtualengine.co.uk

    NAME: VirtualEngine.XDMaintenance
    AUTHOR: Nathan Sperry, Virtual Engine
    LASTEDIT: 31/05/2016
    VERSI0N : 1.0
    WEBSITE: http://www.virtualengine.co.uk

#>

[CmdletBinding()]
param (

    [Parameter(ParameterSetName='1')] [Switch] $NotificationOnly,
    [Parameter(Mandatory,ParameterSetName='1')] [ValidateSet('Information','Critical','Exclamation','Question')] [String] $MessageStyle,
    [Parameter(Mandatory,ParameterSetName='1')] [String] $Title,
    [Parameter(Mandatory,ParameterSetName='1')] [String] $Text,
    [Parameter(ParameterSetName='2')] [Switch] $RestartOnly,
    [Parameter(ParameterSetName='3')] [Switch] $LogOffOnly,
    [Parameter(ParameterSetName='4')] [Switch] $LogOffAndRestart,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [array] $DeliveryGroup,
    [string] $ExcludeUserADGroup

)

function Send-Notification {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [ValidateSet('Information','Critical','Exclamation','Question')] [String] $MessageStyle,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Title,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Text

    )
    
    Begin{} 

    Process {
        
        $notificationMessageParams = @{
        MessageStyle = $MessageStyle
        Title = $Title;
        Text = $Text;
        }
        $connectedDesktopSessions | Send-BrokerSessionMessage @notificationMessageParams;
    }
    
    End{}

}

function Invoke-Logoff {
    [CmdletBinding()]
    param (
    )

    Begin{} 

    Process {
        
        $connectedDesktopSessions | Stop-BrokerSession;

    }
    
    End{}

}

function Invoke-PowerAction {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [ValidateSet('Reset','Restart','Resume','Shutdown','Suspend','TurnOff','TurnOn')] [String] $PowerAction
    )

    Begin{}

    Process {
        
        $Desktops = Get-BrokerDesktop | Where { $_.DesktopGroupName -in $DeliveryGroup -and
                                                $_.PowerState -eq 'On' -and
                                                $_.SessionState -ne 'Active' -and # Don't restart if user logged oon
                                                $_.WillShutdownAfterUse -eq $False};
        $Desktops | ForEach-Object {
        ## ActualPriority: specifies an initial priority for the action in the queue. This priority is the current action priority;
        ##    the 'base' priority for actions created via this cmdlet is always 30. Numerically lower priority values indicate more
        ##    important actions that will be processed in preference to actions with numerically higher priority settings.
        ## Action: Reset, Restart, Resume, Shutdown, Suspend, TurnOff, TurnOn
        New-BrokerHostingPowerAction -MachineName $_.MachineName -Action $PowerAction | out-null;
        }

    }
    
    End{}

}

Function Get-BasicADObject 
{ 
<# 
    .SYNOPSIS  
        Function allow to get AD object info without AD Module. 
 
    .DESCRIPTION  
        Use Get-BasicADObject to get information about Active Directory object's. 
 
    .PARAMETER Filter  
        Filter objects, default search information about users. 
 
    .PARAMETER $Ldap 
        LDAP Path to object. 
         
    .EXAMPLE  
        Get-BasicADObject -Filter '(memberOf=CN=Domain Admins,CN=Users,DC=dev,DC=local)'
 
    .NOTES  
        Author: Michal Gajda  
#> 
    [CmdletBinding( 
        SupportsShouldProcess=$True, 
        ConfirmImpact="Low" 
    )] 
    param 
    ( 
        [String]$Ldap = "dc="+$env:USERDNSDOMAIN.replace(".",",dc="),         
        [String]$Filter = "(&(objectCategory=person)(objectClass=user))" 
    ) 
 
    Begin{} 
 
    Process 
    { 
        if ($pscmdlet.ShouldProcess($Ldap,"Get information about AD Object")) 
        { 
            $searcher=[adsisearcher]$Filter 
             
            $Ldap = $Ldap.replace("LDAP://","") 
            $searcher.SearchRoot="LDAP://$Ldap" 
            $results=$searcher.FindAll() 
     
            $ADObjects = @() 
            foreach($result in $results) 
            { 
                [Array]$propertiesList = $result.Properties.PropertyNames 
                $obj = New-Object PSObject 
                foreach($property in $propertiesList) 
                {  
                    $obj | add-member -membertype noteproperty -name $property -value ([string]$result.Properties.Item($property)) 
                } 
                $ADObjects += $obj 
            } 
       
            Return $ADObjects 
        } 
    } 
     
    End{} 
}

Measure-Command {

Add-PSSnapin -Name Citrix.Broker.Admin.V2;

## Change this to suit where AD Group resides i.e. 'OU=Groups,DC=mydomain,DC=com'
#$LDAP = 'CN=Users,DC=dev,DC=local'

## Returns the Distingished Name of the AD Group
$dn = Get-BasicADObject -Filter "(&(objectCategory=group)(cn=$ExcludeUserADGroup))" | Select-Object -ExpandProperty distinguishedname

## Query members of the AD Group and select the UPN property i.e firstname.surname@domain.local
#$ExcludeUsers = Get-BasicADObject -Filter "(&(memberOf=CN=$ExcludeUserADGroup,$LDAP)(userprincipalname=*))" | Select-Object -ExpandProperty userprincipalname;
$ExcludeUsers = Get-BasicADObject -Filter "(&(memberOf=$dn)(userprincipalname=*))" | Select-Object -ExpandProperty userprincipalname;

## None of the cmdlet properties can take an array. The retrieves all sessions and THEN filters down to just HDX and RDP sessions, Delivery Group, Session State and the Logged on User..
$connectedDesktopSessions = Get-BrokerSession | Where { $_.Protocol -in 'HDX','RDP'-and
                                                        $_.DesktopGroupName -in $DeliveryGroup -and
                                                        #$_.UserFullName -notin $ExcludeUsers -and
                                                        $_.UserUPN -notin $ExcludeUsers -and
                                                        $_.MachineSummaryState -in 'InUse','Disconnected'};

## Send Notication Message Only
If ($NotificationOnly) {Send-Notification -MessageStyle $MessageStyle -Title "$Title" -Text "$Text"};

## Log Session Off : In the case of a pooled desktop this will trigger a restart
If ($LogOffOnly) {Invoke-Logoff};

## Restart Desktops
If ($RestartOnly) {Invoke-PowerAction -PowerAction Restart};

## LogOff & Restart Desktops - Not sure if this will really work i.e. returns logoff successful before its finished
## so PowerAction will start before logoff is finished.
If ($LogOffAndRestart) {
    Invoke-Logoff
    Invoke-PowerAction -PowerAction Restart
    };

};