#########################################################################
# $Id: 98_THINKINGCLEANER.pm 1 2015-08-19 18:21:59Z d.schoen $
# fhem Modul für ThinkingCleaner
#   
#     This file is part of fhem.
# 
#     Fhem is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 2 of the License, or
#     (at your option) any later version.
# 
#     Fhem is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
# 
#     You should have received a copy of the GNU General Public License
#     along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
##############################################################################
#   Changelog:
#
#   2015-08-19  initial version
#
#
#
                    
package main;

use strict;                          
use warnings;                        
use Time::HiRes qw(gettimeofday);    
use HttpUtils;

sub THINKINGCLEANER_Initialize($);
sub THINKINGCLEANER_Define($$);
sub THINKINGCLEANER_Undef($$);
sub THINKINGCLEANER_Set($@);
sub THINKINGCLEANER_Get($@);
sub THINKINGCLEANER_Attr(@);
sub THINKINGCLEANER_GetUpdate($);
sub THINKINGCLEANER_Read($$$);
sub THINKINGCLEANER_AddToQueue($$$$$;$$$);

#
# FHEM module intitialisation
# defines the functions to be called from FHEM
#########################################################################
sub THINKINGCLEANER_Initialize($)
{
    my ($hash) = @_;

    $hash->{DefFn}   = "THINKINGCLEANER_Define";
    $hash->{UndefFn} = "THINKINGCLEANER_Undef";
    $hash->{SetFn}   = "THINKINGCLEANER_Set";
    $hash->{GetFn}   = "THINKINGCLEANER_Get";
    $hash->{AttrFn}  = "THINKINGCLEANER_Attr";
    $hash->{AttrList} =
      "useCallback " .    # new syntax for readings
      $readingFnAttributes;  
}

#########################
sub THINKINGCLEANER_addExtension($$) {
    my ( $name, $func ) = @_;

    my $url = "/$name";
    Log3 $name, 1, "Registering THINKINGCLEANER WebHook $name ";
    $data{FWEXT}{$url}{deviceName} = $name;
    $data{FWEXT}{$url}{FUNC}       = $func;
}

#########################
sub THINKINGCLEANER_removeExtension($) {
    my ($link) = @_;

    my $url  = "/$link";
    my $name = $data{FWEXT}{$url}{deviceName};
    Log3 $name, 1, "Unregistering THINKINGCLEANER WebHook $name ";
    delete $data{FWEXT}{$url};
}

#
# Define command
# init internal values,
# set internal timer get Updates
#########################################################################
sub THINKINGCLEANER_Define($$)
{
    my ( $hash, $def ) = @_;
    my @a = split( "[ \t][ \t]*", $def );


    return "wrong syntax: define <name> THINKINGCLEANER URL interval"
      if ( @a < 3 );
    my $name    = $a[0];

    $hash->{fhem}{tc_infix} = $name;

    THINKINGCLEANER_addExtension( $name, "THINKINGCLEANER_CGI" );

    if ($a[2] eq "none") {
        Log3 $name, 3, "$name: URL is none, no periodic updates will be limited to explicit GetXXPoll attribues (if defined)";
        $hash->{MainURL}    = "";
    } else {
        $hash->{MainURL}    = $a[2];
    }

    if(int(@a) > 3) { 
        if ($a[3] > 0) {
            if ($a[3] >= 5) {
                $hash->{Interval} = $a[3];
            } else {
                return "interval too small, please use something > 5, default is 60";
            }
        } else {
            Log3 $name, 3, "$name: interval is 0, no periodic updates will done.";
            $hash->{Interval} = 0;
        }
    } else {
        $hash->{Interval} = 60;
    }

    Log3 $name, 3, "$name: Defined with URL $hash->{MainURL} and interval $hash->{Interval}";

    # Initial request after 2 secs, for further updates the timer will be set according to interval.
    # but only if URL is specified and interval > 0
    if ($hash->{MainURL} && $hash->{Interval}) {
        my $firstTrigger = gettimeofday() + 2;
        $hash->{TRIGGERTIME}     = $firstTrigger;
        $hash->{TRIGGERTIME_FMT} = FmtDateTime($firstTrigger);
        RemoveInternalTimer("update:$name");
        InternalTimer($firstTrigger, "THINKINGCLEANER_GetUpdate", $name, 0);
        Log3 $name, 5, "$name: InternalTimer set to call GetUpdate in 2 seconds for the first time";
    } else {
       $hash->{TRIGGERTIME} = 0;
       $hash->{TRIGGERTIME_FMT} = "";
    }
    return undef;
}

#
# undefine command when device is deleted
#########################################################################
sub THINKINGCLEANER_Undef($$)
{                     
    my ( $hash, $arg ) = @_;       
    my $name = $hash->{NAME};
    RemoveInternalTimer ("timeout:$name");
    RemoveInternalTimer ("queue:$name"); 
    RemoveInternalTimer ("update:$name"); 
	THINKINGCLEANER_removeExtension( $hash->{fhem}{tc_infix} );
    return undef;                  
}    


#
# Attr command 
#########################################################################
sub
THINKINGCLEANER_Attr(@)
{
    my ($cmd,$name,$aName,$aVal) = @_;
    # $cmd can be "del" or "set"
    # $name is device name
    # aName and aVal are Attribute name and value

    # simple attributes like requestHeader and requestData need no special treatment here
    # readingsExpr, readingsRegex.* or reAuthRegex need validation though.
    
    if ($cmd eq "set") {        
        addToDevAttrList($name, $aName);
    }
    return undef;
}

# put URL, Header, Data etc. in hash for HTTPUtils Get
# for set with index $setNum
#########################################################################
sub THINKINGCLEANER_DoSet($$$)
{
    my ($hash, $setNum, $rawVal) = @_;
    my $name = $hash->{NAME};
    my ($url, $header, $data, $type, $count);
    
    # hole alle Header bzw. generischen Header ohne Nummer 
    $header = join ("\r\n", map ($attr{$name}{$_}, sort grep (/set${setNum}Header/, keys %{$attr{$name}})));
    if (length $header == 0) {
        $header = join ("\r\n", map ($attr{$name}{$_}, sort grep (/setHeader/, keys %{$attr{$name}})));
    }
    # hole Bestandteile der Post data 
    $data = join ("\r\n", map ($attr{$name}{$_}, sort grep (/set${setNum}Data/, keys %{$attr{$name}})));
    if (length $data == 0) {
        $data = join ("\r\n", map ($attr{$name}{$_}, sort grep (/setData/, keys %{$attr{$name}})));
    }
    # hole URL
    $url = AttrVal($name, "set${setNum}URL", undef);
    if (!$url) {
        $url = AttrVal($name, "setURL", undef);
    }
    if (!$url) {
        $url = $hash->{MainURL};
    }
    
    # ersetze $val in header, data und URL
    $header =~ s/\$val/$rawVal/g;
    $data   =~ s/\$val/$rawVal/g;
    $url    =~ s/\$val/$rawVal/g;
 
    $type = "Set$setNum";

    if ($url) {
        THINKINGCLEANER_AddToQueue($hash, $url, $header, $data, $type); 
    } else {
        Log3 $name, 3, "$name: no URL for $type";
    }
    
    return undef;
}


#
# SET command
#########################################################################
sub THINKINGCLEANER_Set($@)
{
    my ( $hash, @args ) = @_;
    return "\"set THINKINGCLEANER\" needs at least an argument" if ( @args < 2 );

    if ($args[1] eq 'clean') {
			THINKINGCLEANER_AddToQueue($hash, $hash->{'MainURL'}."/command.json?command=".$args[1], undef, undef, undef)
		} elsif ($args[1] eq 'spot') {
			THINKINGCLEANER_AddToQueue($hash, $hash->{'MainURL'}."/command.json?command=".$args[1], undef, undef, undef)
		} elsif ($args[1] eq 'dock') {
			THINKINGCLEANER_AddToQueue($hash, $hash->{'MainURL'}."/command.json?command=".$args[1], undef, undef, undef)
		} else {
	        return "clean:noArg dock:noArg spot:noArg";
	  }
	    return undef;
    
}



# put URL, Header, Data etc. in hash for HTTPUtils Get
# for get with index $getNum
#########################################################################
sub THINKINGCLEANER_DoGet($$)
{
    my ($hash, $getNum) = @_;
    my $name = $hash->{NAME};
    my ($url, $header, $data, $type, $count);
    
    # hole alle Header bzw. generischen Header ohne Nummer 
    $header = join ("\r\n", map ($attr{$name}{$_}, sort grep (/get${getNum}Header/, keys %{$attr{$name}})));
    if (length $header == 0) {
        $header = join ("\r\n", map ($attr{$name}{$_}, sort grep (/getHeader/, keys %{$attr{$name}})));
    }
    if (AttrVal($name, "get${getNum}HdrExpr", undef)) {
        my $exp = AttrVal($name, "get${getNum}HdrExpr", undef);
        my $old = $header;
        $header = eval($exp);
        Log3 $name, 5, "$name: get converted the header $old\n to $header\n using expr $exp";
    }   
    
    # hole Bestandteile der Post data 
    $data = join ("\r\n", map ($attr{$name}{$_}, sort grep (/get${getNum}Data/, keys %{$attr{$name}})));
    if (length $data == 0) {
        $data = join ("\r\n", map ($attr{$name}{$_}, sort grep (/getData/, keys %{$attr{$name}})));
    }
    if (AttrVal($name, "get${getNum}DatExpr", undef)) {
        my $exp = AttrVal($name, "get${getNum}DatExpr", undef);
        my $old = $data;
        $data = eval($exp);
        Log3 $name, 5, "$name: get converted the post data $old\n to $data\n using expr $exp";
    }   

    # hole URL
    $url = AttrVal($name, "get${getNum}URL", undef);
    if (!$url) {
        $url = AttrVal($name, "getURL", undef);
    }
    if (AttrVal($name, "get${getNum}URLExpr", undef)) {
        my $exp = AttrVal($name, "get${getNum}URLExpr", undef);
        my $old = $url;
        $url = eval($exp);
        Log3 $name, 5, "$name: get converted the url $old to $url using expr $exp";
    }   
    if (!$url) {
        $url = $hash->{MainURL};
    }
    
    $type = "Get$getNum";

    if ($url) {
        THINKINGCLEANER_AddToQueue($hash, $url, $header, $data, $type); 
    } else {
        Log3 $name, 3, "$name: no URL for $type";
    }
    
    return undef;
}


#
# GET command
#########################################################################
sub THINKINGCLEANER_Get($@)
{
    my ( $hash, @a ) = @_;
    return "\"get THINKINGCLEANER\" needs at least an argument" if ( @a < 2 );
    
    # @a is an array with DeviceName, getName
    my ($name, $getName) = @a;
    my ($getNum, $getList);
    $getList = "";

    if (AttrVal($name, "disable", undef)) {
        Log3 $name, 5, "$name: get called with $getName but device is disabled"
            if ($getName ne "?");
        return undef;
    }
    
    Log3 $name, 5, "$name: get called with $getName "
        if ($getName ne "?");

    # verarbeite Attribute "get[0-9]*Name  get[0-9]*URL  get[0-9]*Data.*  get[0-9]*Header.* 
    
    # Vorbereitung:
    # suche den übergebenen getName in den Attributen, setze getNum falls gefunden
    foreach my $aName (keys %{$attr{$name}}) {
        if ($aName =~ "get([0-9]+)Name") {      # ist das Attribut ein "getXName" ?
            my $getI  = $1;                     # merke die Nummer im Namen
            my $iName = $attr{$name}{$aName};   # Name der get-Option diser Schleifen-Iteration
            
            if ($getName eq $iName) {           # ist es der im konkreten get verwendete getName?
                $getNum = $getI;                # gefunden -> merke Nummer X im Attribut
            }
            $getList .= $iName . " ";           # speichere Liste mit allen gets für Rückgabe bei get ?
        }
    }
    
    # gültiger get Aufruf? ($getNum oben schon gesetzt?)
    if(!defined ($getNum)) {
        return "Unknown argument $getName, choose one of $getList";
    } 
    Log3 $name, 5, "$name: get found option $getName in attribute get${getNum}Name";
    Log3 $name, 4, "$name: get will now request $getName";

    my $result = THINKINGCLEANER_DoGet($hash, $getNum);
    return "$getName requested, watch readings";
}



#
# request new data from device
###################################
sub THINKINGCLEANER_GetUpdate($)
{
    my $name = $_[0];
    my $hash = $defs{$name};
    my ($url, $header, $data, $type, $count);
    my $now = gettimeofday();
    
    
    if ( $hash->{Interval}) {
        RemoveInternalTimer ($name);
        my $nt = gettimeofday() + $hash->{Interval};
        $hash->{TRIGGERTIME}     = $nt;
        $hash->{TRIGGERTIME_FMT} = FmtDateTime($nt);
        InternalTimer($nt, "THINKINGCLEANER_GetUpdate", $name, 0);
        Log3 $name, 5, "$name: internal interval timer set to call GetUpdate again in " . int($hash->{Interval}). " seconds";
    }
    
    if (AttrVal($name, "disable", undef)) {
        Log3 $name, 5, "$name: GetUpdate called but device is disabled";
        return undef;
    }
    
    if ( $hash->{MainURL} ne "none" ) {
        $url    = $hash->{MainURL};
        $header = join ("\r\n", map ($attr{$name}{$_}, sort grep (/requestHeader/, keys %{$attr{$name}})));
        $data   = join ("\r\n", map ($attr{$name}{$_}, sort grep (/requestData/, keys %{$attr{$name}})));
        $type   = "Update";
        
        # queue main get request 
        if ($url) {
            THINKINGCLEANER_AddToQueue($hash, $url."/full_status.json", $header, $data, $type); 
        } else {
            Log3 $name, 3, "$name: no URL for $type";
        }
    }
}


# get attribute based specification
# for format, map or similar
# with generic default (empty variable part)
#############################################
sub THINKINGCLEANER_GetFAttr($$$$)
{
    my ($name, $prefix, $num, $type) = @_;
    my $val = "";
    if (defined ($attr{$name}{$prefix . $num . $type})) {
          $val = $attr{$name}{$prefix . $num . $type};
    } elsif 
       (defined ($attr{$name}{$prefix . $type})) {
          $val = $attr{$name}{$prefix . $type};
    }
    return $val;
}



#
# read / parse new data from device
# - callback for non blocking HTTP 
###################################
sub THINKINGCLEANER_Read($$$)
{
    my ($hash, $err, $buffer) = @_;
    my $name    = $hash->{NAME};
    my $request = $hash->{REQUEST};
    my $type    = $request->{type};
    
    $hash->{BUSY} = 0;
    RemoveInternalTimer ($hash); # Remove remaining timeouts of HttpUtils (should be done in HttpUtils)
    eval {
		my $perl_scalar = decode_json $buffer;
    	readingsBeginUpdate($hash);

    	for my $key ( keys $perl_scalar ) {
			my $value = $perl_scalar->{$key};
			if (ref($value) eq "HASH") {
				for my $subkey ( keys $value ) {
					my $subvalue = $value->{$subkey};
					if (!(exists $hash->{READINGS}->{$key."_".$subkey}) || ($hash->{READINGS}->{$key."_".$subkey}->{VAL} ne $subvalue)){	
						if ($key eq "tc_status" && $subkey eq "cleaning_distance"){
							my $relVal = $hash->{READINGS}->{"tc_status_cleaning_dist_rel"}->{VAL};
							$relVal = $relVal + $subvalue- $hash->{READINGS}->{"tc_status_cleaning_distance"}->{VAL};
							readingsBulkUpdate( $hash, "tc_status_cleaning_dist_rel",  $relVal);
						}					
						readingsBulkUpdate( $hash, $key."_".$subkey, $subvalue );
						if ($key eq "power_status" && $subkey eq "cleaner_state" && substr($subvalue, 0, 7) eq "st_base"){
							readingsBulkUpdate( $hash, "tc_status_cleaning_dist_rel", 0);
						}
						
					} 
				}
			} else {
				if (!(exists $hash->{READINGS}->{$key}) || ($hash->{READINGS}->{$key}->{VAL} ne $value)){
					readingsBulkUpdate( $hash, $key, $value );
				} 
			}
		}
		readingsEndUpdate($hash,1);
		return undef;
    
	} or do {
	  	my $e = $@;
		return undef;
	}
    
}



#######################################
# Aufruf aus InternalTimer mit "queue:$name" 
# oder direkt mit $direct:$name
sub
THINKINGCLEANER_HandleSendQueue($)
{
  my (undef,$name) = split(':', $_[0]);
  my $hash  = $defs{$name};
  my $queue = $hash->{QUEUE};
  
  my $qlen = ($hash->{QUEUE} ? scalar(@{$hash->{QUEUE}}) : 0);
  Log3 $name, 5, "$name: HandleSendQueue called, qlen = $qlen";
  RemoveInternalTimer ("queue:$name");
  
  if(defined($queue) && @{$queue} > 0) {
  
    my $queueDelay  = AttrVal($name, "queueDelay", 1);  
    my $now = gettimeofday();
  
    if (!$init_done) {      # fhem not initialized, wait with IO
      InternalTimer($now+$queueDelay, "THINKINGCLEANER_HandleSendQueue", "queue:$name", 0);
      Log3 $name, 3, "$name: HandleSendQueue - init not done, delay sending from queue";
      return;
    }
    if ($hash->{BUSY}) {  # still waiting for reply to last request
      InternalTimer($now+$queueDelay, "THINKINGCLEANER_HandleSendQueue", "queue:$name", 0);
      Log3 $name, 5, "$name: HandleSendQueue - still waiting for reply to last request, delay sending from queue";
      return;
    }

    $hash->{REQUEST} = $queue->[0];

    if($hash->{REQUEST}{url} ne "") {    # if something to send - check min delay and send
        my $minSendDelay = AttrVal($hash->{NAME}, "minSendDelay", 0.2);

        if ($hash->{LASTSEND} && $now < $hash->{LASTSEND} + $minSendDelay) {
            InternalTimer($now+$queueDelay, "THINKINGCLEANER_HandleSendQueue", "queue:$name", 0);
            Log3 $name, 5, "$name: HandleSendQueue - minSendDelay not over, rescheduling";
            return;
        }   
        
        $hash->{BUSY}      = 1;         # THINKINGCLEANER queue is busy until response is received
        $hash->{LASTSEND}  = $now;      # remember when last sent
        $hash->{redirects} = 0;
        $hash->{callback}  = \&THINKINGCLEANER_Read;
        $hash->{url}       = $hash->{REQUEST}{url};
        $hash->{header}    = $hash->{REQUEST}{header};
        $hash->{data}      = $hash->{REQUEST}{data};     
        $hash->{timeout}   = AttrVal($name, "timeout", 2);
        $hash->{ignoreredirects} = $hash->{REQUEST}{ignoreredirects};
      
        if (AttrVal($name, "noShutdown", undef)) {
            $hash->{noshutdown} = 1;
        } else {
            delete $hash->{noshutdown};
        };

        if ($hash->{sid}) {
            $hash->{header} =~ s/\$sid/$hash->{sid}/g;
            $hash->{data}   =~ s/\$sid/$hash->{sid}/g;
            $hash->{url}    =~ s/\$sid/$hash->{sid}/g;
        }
        
        Log3 $name, 4, "$name: HandleSendQueue sends request type $hash->{REQUEST}{type} to " .
                        "URL $hash->{url}, data $hash->{data}, header $hash->{header}, timeout $hash->{timeout}";
        HttpUtils_NonblockingGet($hash);
    }
    shift(@{$queue});           # remove first element from queue
    if(@{$queue} > 0) {         # more items in queue -> schedule next handle 
        InternalTimer($now+$queueDelay, "THINKINGCLEANER_HandleSendQueue", "queue:$name", 0);
    }
  }
}



#####################################
sub THINKINGCLEANER_AddToQueue($$$$$;$$$){
    my ($hash, $url, $header, $data, $type, $count, $ignoreredirects, $prio) = @_;
    my $name = $hash->{NAME};

    $count           = 0 if (!$count);
    $ignoreredirects = 0 if (!$ignoreredirects);
    
    my %request;
    $request{url}             = $url;
    $request{header}          = $header;
    $request{data}            = $data;
    $request{type}            = $type;
    $request{retryCount}      = $count;
    $request{ignoreredirects} = $ignoreredirects;
    
    my $qlen = ($hash->{QUEUE} ? scalar(@{$hash->{QUEUE}}) : 0);
    Log3 $name, 5, "$name: AddToQueue called, initial send queue length : $qlen";
    Log3 $name, 5, "$name: AddToQueue adds type $request{type} to " .
            "URL $request{url}, data $request{data}, header $request{header}";
    if(!$qlen) {
        $hash->{QUEUE} = [ \%request ];
    } else {
        if ($qlen > AttrVal($name, "queueMax", 20)) {
            Log3 $name, 3, "$name: AddToQueue - send queue too long, dropping request";
        } else {
            if ($prio) {
                unshift (@{$hash->{QUEUE}}, \%request); # an den Anfang
            } else {
                push(@{$hash->{QUEUE}}, \%request);     # ans Ende
            }
        }
    }
    THINKINGCLEANER_HandleSendQueue("direct:".$name);
}

############################################################################################################
#
#   Begin of helper functions
#
############################################################################################################

###################################
sub THINKINGCLEANER_CGI() {
    THINKINGCLEANER_GetUpdate("roomba");
    
	Log3 "ThinkingCleaner_CLI", 1, "WebHook called";
    my $msg = "OK";
    return ( "text/plain; charset=utf-8", $msg );
}

sub THINKINGCLEANER_ISO8601UTCtoLocal ($) {
    my ($datetime) = @_;
    $datetime =~ s/T/ /g if ( defined( $datetime && $datetime ne "" ) );
    $datetime =~ s/Z//g  if ( defined( $datetime && $datetime ne "" ) );

    my (
        $date, $time, $y,     $m,       $d,       $hour,
        $min,  $sec,  $hours, $minutes, $seconds, $timestamp
    );

    ( $date, $time ) = split( ' ', $datetime );
    ( $y,    $m,   $d )   = split( '-', $date );
    ( $hour, $min, $sec ) = split( ':', $time );
    $m -= 01;
    $timestamp = timegm( $sec, $min, $hour, $d, $m, $y );
    ( $sec, $min, $hour, $d, $m, $y ) = localtime($timestamp);
    $timestamp = timelocal( $sec, $min, $hour, $d, $m, $y );

    return $timestamp;
}

1;

=pod
=begin html

<a name="THINKINGCLEANER"></a>
<h3>THINKINGCLEANER</h3>

<ul>
    This module provides a generic way to communicate with a Thinking Cleaner (http://www.thinkingcleaner.com/) add on for your Roomba. 
     <br><br>
    <b>Prerequisites</b>
    <ul>
        <br>
        <li>
            This Module uses the non blocking HTTP function HttpUtils_NonblockingGet provided by FHEM's HttpUtils in a new Version published in December 2013.<br>
            If not already installed in your environment, please update FHEM or install it manually using appropriate commands from your environment.<br>
        </li>
        
    </ul>
    <br>

    <a name="THINKINGCLEANERdefine"></a>
    <b>Define</b>
    <ul>
        <br>
        <code>define &lt;name&gt; THINKINGCLEANER &lt;URL&gt; &lt;Interval&gt;</code>
        <br><br>
        The module connects to the given URL every Interval seconds, sends optional headers and data and then parses the response<br>
        <br>
        Example:<br>
        <br>
        <ul><code>define PM THINKINGCLEANER http://MyPoolManager/cgi-bin/webgui.fcgi 60</code></ul>
    </ul>
    <br>

    <a name="THINKINGCLEANERconfiguration"></a>
    <b>Configuration of HTTP Devices</b><br><br>
    <ul>
        Specify optional headers as <code>attr requestHeader1</code> to <code>attr requestHeaderX</code>, <br>
        optional POST data as <code>attr requestData</code> and then <br>
        pairs of <code>attr readingXName</code> and <code>attr readingXRegex</code> to define which readings you want to extract from the HTTP
        response and how to extract them. (The old syntax <code>attr readingsNameX</code> and <code>attr readingsRegexX</code> is still supported 
        but the new one with <code>attr readingXName</code> and <code>attr readingXRegex</code> should be preferred.
        <br><br>
        Example for a PoolManager 5:<br><br>
        <ul><code>
            define PM THINKINGCLEANER http://MyPoolManager/cgi-bin/webgui.fcgi 60<br>
            attr PM reading01Name PH<br>
            attr PM reading01Regex 34.4001.value":[ \t]+"([\d\.]+)"<br>
            <br>
            attr PM reading02Name CL<br>
            attr PM reading02Regex 34.4008.value":[ \t]+"([\d\.]+)"<br>
            <br>
            attr PM reading03Name3TEMP<br>
            attr PM reading03Regex 34.4033.value":[ \t]+"([\d\.]+)"<br>
            <br>
            attr PM requestData {"get" :["34.4001.value" ,"34.4008.value" ,"34.4033.value", "14.16601.value", "14.16602.value"]}<br>
            attr PM requestHeader1 Content-Type: application/json<br>
            attr PM requestHeader2 Accept: */*<br>
            attr PM stateFormat {sprintf("%.1f Grad, PH %.1f, %.1f mg/l Chlor", ReadingsVal($name,"TEMP",0), ReadingsVal($name,"PH",0), ReadingsVal($name,"CL",0))}<br>
        </code></ul>
        <br>
        If you need to do some calculation on a raw value before it is used as a reading, you can define the attribute <code>readingXExpr</code> 
        which can use the raw value from the variable $val
        <br><br>
        Example:<br><br>
        <ul><code>
            attr PM reading03Expr $val * 10<br>
        </code></ul>


        <br><br>
        <b>Advanced configuration to define a <code>set</code> or <code>get</code> and send data to a device</b>
        <br><br>
        
        When a set option is defined by attributes, the module will use the value given to the set command and translate it into an HTTP-Request that sends the value to the device. <br><br>
        Extension to the above example for a PoolManager 5:<br><br>
        <ul><code>
            attr PM set01Name HeizungSoll <br>
            attr PM set01URL http://MyPoolManager/cgi-bin/webgui.fcgi?sid=$sid <br>
            attr PM set01Hint 6,10,20,30 <br>
            attr PM set01Min 6 <br>
            attr PM set01Max 30 <br>
            attr PM setHeader1 Content-Type: application/json <br>
            attr PM set01Data {"set" :{"34.3118.value" :"$val" }} <br>
        </code></ul>
        <br>
        This example defines a set option with the name HeizungSoll. <br>
        By issuing <code>set PM HeizungSoll 10</code> in FHEM, the value 10 will be sent in the defined HTTP
        Post to URL <code>http://MyPoolManager/cgi-bin/webgui.fcgi</code> in the Post Data as <br>
        <code>{"set" :{"34.3118.value" :"10" }}</code><br>
        The optional attributes set01Min and set01Max define input validations that will be checked in the set function.<br>
        the optional attribute set01Hint will define a selection list for the Fhemweb GUI.<br><br>

        When a get option is defined by attributes, the module allows querying additional values from the device that require 
        individual HTTP-Requests or special parameters to be sent<br><br>
        Extension to the above example:<br><br>
        <ul><code>
            attr PM get01Name MyGetValue <br>
            attr PM get01URL http://MyPoolManager/cgi-bin/directory/webgui.fcgi?special=1?sid=$sid <br>
            attr PM getHeader1 Content-Type: application/json <br>
            attr PM get01Data {"get" :{"30.1234.value"}} <br>
        </code></ul>
        <br>
        This example defines a get option with the name MyGetValue. <br>
        By issuing <code>get PM MyGetValue</code> in FHEM, the defined HTTP request is sent to the device.<br>
        The HTTP response is then parsed using the same readingXXName and readingXXRegex attributes as above so
        additional pairs will probably be needed there for additional values.<br><br>
        
        If the new get parameter should also be queried regularly, you can define the following optional attributes:<br>
        <ul><code>
            attr PM get01Poll 1<br>
            attr PM get01PollDelay 300<br>
        </code></ul>
        <br>

        The first attribute includes this reading in the automatic update cycle and the second defines an
        alternative lower update frequency. When the interval defined initially is over and the normal readings
        are read from the device, the update function will check for additional get parameters that should be included
        in the update cycle.
        If a PollDelay is specified for a get parameter, the update function also checks if the time passed since it has last read this value 
        is more than the given PollDelay. If not, this reading is skipped and it will be rechecked in the next cycle when 
        interval is over again. So the effective PollDelay will always be a multiple of the interval specified in the initial define.
        
        <br><br>
        <b>Advanced configuration to create a valid session id that might be necessary in set options</b>
        <br><br>
        when sending data to an HTTP-Device in a set, THINKINGCLEANER will replace any <code>$sid</code> in the URL, Headers and Post data with the internal <code>$hash->{sid}</code>. To authenticate towards the device and give this internal a value, you can use an optional multi step login procedure defined by the following attributes: <br>
        <ul>
        <li>sid[0-9]*URL</li>
        <li>sid[0-9]*IDRegex</li>
        <li>sid[0-9]*Data.*</li>
        <li>sid[0-9]*Header.*</li>
        </ul><br>
        Each step can have a URL, Headers, Post Data pieces and a Regex to extract a resulting Session ID into <code>$hash->{sid}</code>.<br>
        THINKINGCLEANER will create a sorted list of steps (the numbers between sid and URL / Data / Header) and the loop through these steps and send the corresponding requests to the device. For each step a $sid in a Header or Post Data will be replaced with the current content of <code>$hash->{sid}</code>. <br>
        Using this feature, THINKINGCLEANER can perform a forms based authentication and send user name, password or other necessary data to the device and save the session id for further requests. <br><br>
        
        To determine when this login procedure is necessary, THINKINGCLEANER will first try to do a set without 
        doing the login procedure. If the Attribute ReAuthRegex is defined, it will then compare the HTTP Response to the set request with the regular expression from ReAuthRegex. If it matches, then a 
        login is performed. The ReAuthRegex is meant to match the error page a device returns if authentication or reauthentication is required e.g. because a session timeout has expired. <br><br>
        
        If for one step not all of the URL, Data or Header Attributes are set, then THINKINGCLEANER tries to use a 
        <code>sidURL</code>, <code>sidData.*</code> or <code>sidHeader.*</code> Attribue (without the step number after sid). This way parts that are the same for all steps don't need to be defined redundantly. <br><br>
        
        Example for a multi step login procedure: 
        <br><br>
        
        <ul><code>
            attr PM sidURL http://192.168.70.90/cgi-bin/webgui.fcgi?sid=$sid<br>
            attr PM sidHeader1 Content-Type: application/json<br>
            attr PM sid1IDRegex wui.init\('([^']+)'<br>
            attr PM sid2Data {"set" :{"9.17401.user" :"fhem" ,"9.17401.pass" :"password" }}<br>
            attr PM sid3Data {"set" :{"35.5062.value" :"128" }}<br>
            attr PM sid4Data {"set" :{"42.8026.code" :"pincode" }}<br>
        </ul></code>
        
    </ul>
    <br>

    <a name="THINKINGCLEANERset"></a>
    <b>Set-Commands</b><br>
    <ul>
        as defined by the attributes set.*Name
        If you set the attribute enableControlSet to 1, the following additional built in set commands are available:<br>
        <ul>
            <li><b>interval</b></li>
                set new interval time in seconds and restart the timer<br>
            <li><b>reread</b></li>
                request the defined URL and try to parse it just like the automatic update would do it every Interval seconds without modifying the running timer. <br>
            <li><b>stop</b></li>
                stop interval timer.<br>
            <li><b>start</b></li>
                restart interval timer to call GetUpdate after interval seconds<br>
        </ul>
        <br>
    </ul>
    <br>
    <a name="THINKINGCLEANERget"></a>
    <b>Get-Commands</b><br>
    <ul>
        as defined by the attributes get.*Name
    </ul>
    <br>
    <a name="THINKINGCLEANERattr"></a>
    <b>Attributes</b><br><br>
    <ul>
        <li><a href="#do_not_notify">do_not_notify</a></li>
        <li><a href="#readingFnAttributes">readingFnAttributes</a></li>
        <br>
        <li><b>requestHeader.*</b></li> 
            Define an optional additional HTTP Header to set in the HTTP request <br>
        <li><b>requestData</b></li>
            optional POST Data to be sent in the request. If not defined, it will be a GET request as defined in HttpUtils used by this module<br>
        <li><b>reading[0-9]+Name</b> or <b>readingsName.*</b></li>
            the name of a reading to extract with the corresponding readingRegex<br>
        <li><b>reading[0-9]+Regex</b> ro <b>readingsRegex.*</b></li>
            defines the regex to be used for extracting the reading. The value to extract should be in a sub expression e.g. ([\d\.]+) in the above example <br>
        <li><b>reading[0-9]*Expr</b> or <b>readingsExpr.*</b></li>
            defines an expression that is used in an eval to compute the readings value. <br>
            The raw value will be in the variable $val.<br>
            If specified as readingExpr then the attribute value is a default for all other readings that don't specify 
            an explicit reading[0-9]*Expr.
        <li><b>reading[0-9]*Map</b></li>
            Map that defines a mapping from raw to visible values like "0:mittig, 1:oberhalb, 2:unterhalb". <br>
            If specified as readingMap then the attribute value is a default for all other readings that don't specify 
            an explicit reading[0-9]*Map.
        <li><b>reading[0-9]*Format</b></li>
            Defines a format string that will be used in sprintf to format a reading value.<br>
            If specified as readingFormat then the attribute value is a default for all other readings that don't specify 
            an explicit reading[0-9]*Format.
        <li><b>noShutdown</b></li>
            pass the noshutdown flag to HTTPUtils for webservers that need it (some embedded webservers only deliver empty pages otherwise)
        <li><b>disable</b></li>
            stop doing automatic HTTP requests while this attribute is set to 1
        <li><b>timeout</b></li>
            time in seconds to wait for an answer. Default value is 2
        <li><b>enableControlSet</b></li>
            enables the built in set commands interval, stop, start, reread.
        <li><b>enableXPath</b></li>
            enables the use of "xpath:" instead of a regular expression to parse the HTTP response
        <li><b>enableXPath-Strict</b></li>
            enables the use of "xpath-strict:" instead of a regular expression to parse the HTTP response
    </ul>
    <br>
    <b> advanced attributes </b>
    <br>
    <ul>
        <li><b>ReAuthRegex</b></li>
            regular Expression to match an error page indicating that a session has expired and a new authentication for read access needs to be done. This attribute only makes sense if you need a forms based authentication for reading data and if you specify a multi step login procedure based on the sid.. attributes.
        <br><br>
        <li><b>sid[0-9]*URL</b></li>
            different URLs or one common URL to be used for each step of an optional login procedure. 
        <li><b>sid[0-9]*IDRegex</b></li>
            different Regexes per login procedure step or one common Regex for all steps to extract the session ID from the HTTP response
        <li><b>sid[0-9]*Data.*</b></li>
            data part for each step to be sent as POST data to the corresponding URL
        <li><b>sid[0-9]*Header.*</b></li>
            HTTP Headers to be sent to the URL for the corresponding step
        <li><b>sid[0-9]*IgnoreRedirects</b></li>
            tell HttpUtils to not follow redirects for this authentication request
        <br>
        <br>
        <li><b>set[0-9]+Name</b></li>
            Name of a set option
        <li><b>set[0-9]*URL</b></li>
            URL to be requested for the set option
        <li><b>set[0-9]*Data</b></li>
            optional Data to be sent to the device as POST data when the set is executed. if this atribute is not specified, an HTTP GET method 
            will be used instead of an HTTP POST
        <li><b>set[0-9]*Header</b></li>
            optional HTTP Headers to be sent to the device when the set is executed
        <li><b>set[0-9]+Min</b></li>
            Minimum value for input validation. 
        <li><b>set[0-9]+Max</b></li>
            Maximum value for input validation. 
        <li><b>set[0-9]+Expr</b></li>
            Perl Expression to compute the raw value to be sent to the device from the input value passed to the set.
        <li><b>set[0-9]+Map</b></li>
            Map that defines a mapping from raw to visible values like "0:mittig, 1:oberhalb, 2:unterhalb". This attribute atomatically creates a hint for FhemWEB so the user can choose one of the visible values.
        <li><b>set[0-9]+Hint</b></li>
            Explicit hint for fhemWEB that will be returned when set ? is seen.
        <li><b>set[0-9]*ReAuthRegex</b></li>
            Regex that will detect when a session has expired an a new login needs to be performed.         
        <li><b>set[0-9]*NoArg</b></li>
            Defines that this set option doesn't require arguments. It allows sets like "on" or "off" without further values.
        <br>
        <br>
        <li><b>get[0-9]+Name</b></li>
            Name of a get option and Reading to be retrieved / extracted
        <li><b>get[0-9]*URL</b></li>
            URL to be requested for the get option. If this option is missing, the URL specified during define will be used.
        <li><b>get[0-9]*Data</b></li>
            optional data to be sent to the device as POST data when the get is executed. if this attribute is not specified, an HTTP GET method 
            will be used instead of an HTTP POST
        <li><b>get[0-9]*Header</b></li>
            optional HTTP Headers to be sent to the device when the get is executed
            
        <li><b>get[0-9]*URLExpr</b></li>
            optional Perl expression that allows modification of the URL at runtime. The origial value is available as $old.
        <li><b>get[0-9]*DatExpr</b></li>
            optional Perl expression that allows modification of the Post data at runtime. The origial value is available as $old.
        <li><b>get[0-9]*HdrExpr</b></li>
            optional Perl expression that allows modification of the Headers at runtime. The origial value is available as $old.
            
        <li><b>get[0-9]+Poll</b></li>
            if set to 1 the get is executed automatically during the normal update cycle (after the interval provided in the define command has elapsed)
        <li><b>get[0-9]+PollDelay</b></li>
            if the value should not be read in each iteration (after the interval given to the define command), then a
            minimum delay can be specified with this attribute. This has only an effect if the above Poll attribute has
            also been set. Every time the update function is called, it checks if since this get has been read the last time, the defined delay has elapsed. If not, then it is skipped this time.<br>
            PollDelay can be specified as seconds or as x[0-9]+ which means a multiple of the interval in the define command.
        <li><b>get[0-9]*Regex</b></li>
            If this attribute is specified, the Regex defined here is used to extract the value from the HTTP Response 
            and assign it to a Reading with the name defined in the get[0-9]+Name attribute.<br>
            if this attribute is not specified for an individual Reading but as getRegex, then it applies to all get options
            where no specific Regex is defined.<br>
            If neither a generic getRegex attribute nor a specific get[0-9]+Regex attribute is specified, then THINKINGCLEANER
            tries all Regex / Reading pairs defined in Reading[0-9]+Name and Reading[0-9]+Regex attributes and assigns the 
            Readings that match.
        <li><b>get[0-9]*Expr</b></li>
            this attribute behaves just like Reading[0-9]*Expr but is applied to a get value. 
        <li><b>get[0-9]*Map</b></li>
            this attribute behaves just like Reading[0-9]*Map but is applied to a get value.
        <li><b>get[0-9]*Format</b></li>
            this attribute behaves just like Reading[0-9]*Format but is applied to a get value.
        <li><b>get[0-9]*CheckAllReadings</b></li>
            this attribute modifies the behavior of THINKINGCLEANER when the HTTP Response of a get command is parsed. <br>
            If this attribute is set to 1, then additionally to any matching of get specific regexes (get[0-9]*Regex), 
            also all the Regex / Reading pairs defined in Reading[0-9]+Name and Reading[0-9]+Regex attributes are checked and if they match, the coresponding Readings are assigned as well.
        <br>
        <li><b>get[0-9]*URLExpr</b></li>
            Defines a Perl expression to specify the HTTP Headers for this request. This overwrites any other header specification and should be used carefully only if needed e.g. to pass additional variable data to a web service. The original Header is availabe as $old.
        <li><b>get[0-9]*DatExpr</b></li>
            Defines a Perl expression to specify the HTTP Post data for this request. This overwrites any other post data specification and should be used carefully only if needed e.g. to pass additional variable data to a web service.
            The original Data is availabe as $old.
        <li><b>get[0-9]*HdrExpr</b></li>
            Defines a Perl expression to specify the URL for this request. This overwrites any other URL specification and should be used carefully only if needed e.g. to pass additional variable data to a web service.
            The original URL is availabe as $old.
        <br>
        <br>
        <li><b>showMatched</b></li>
            if set to 1 then THINKINGCLEANER will create a reading that contains the names of all readings that could be matched in the last request.
        <li><b>queueDelay</b></li>
            HTTP Requests will be sent from a queue in order to avoid blocking when several Requests have to be sent in sequence. This attribute defines the delay between calls to the function that handles the send queue. It defaults to one second.
        <li><b>queueMax</b></li>
            Defines the maximum size of the send queue. If it is reached then further HTTP Requests will be dropped and not be added to the queue
        <li><b>minSendDelay</b></li>
            Defines the minimum time between two HTTP Requests.
    </ul>
    <br>
    <b>Author's notes</b><br><br>
    <ul>
        <li>If you don't know which URLs, headers or POST data your web GUI uses, you might try a local proxy like <a href=http://portswigger.net/burp/>BurpSuite</a> to track requests and responses </li>
    </ul>
</ul>

=end html
=cut
